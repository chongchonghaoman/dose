import AppKit
import CoreImage
import SwiftUI

struct ProjectionPhoto: @unchecked Sendable {
    let url: URL
    let sharp: CGImage
    let soft: CGImage
    let glow: CGImage?
    let glowOutset: CGFloat

    init(url: URL, sharp: CGImage, soft: CGImage, glow: CGImage? = nil, glowOutset: CGFloat = 0) {
        self.url = url; self.sharp = sharp; self.soft = soft
        self.glow = glow; self.glowOutset = glowOutset
    }

    var aspect: CGFloat { CGFloat(sharp.width) / CGFloat(sharp.height) }

    func fittedSize(in container: CGSize) -> CGSize {
        let width = max(0, container.width) * 0.84
        let height = max(0, container.height) * 0.84
        return CGSize(width: min(width, height * aspect), height: min(height, width / aspect))
    }
}

/// Image work runs off the main actor. Animation composites static bitmaps.
actor SlideshowProjectionStore {
    static let shared = SlideshowProjectionStore()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [URL: ProjectionPhoto] = [:]
    private var recent: [URL] = []

    func photo(_ url: URL) async -> ProjectionPhoto? {
        if let value = cache[url] { touch(url); return value }
        guard !Task.isCancelled, let preview = await PhotoStore.shared.preview(url),
              !Task.isCancelled else { return nil }
        if let value = cache[url] { touch(url); return value }
        guard let value = render(preview.lit, url: url) else { return nil }
        cache[url] = value
        touch(url)
        while recent.count > 3 { cache.removeValue(forKey: recent.removeFirst()) }
        return value
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
    }

    func render(_ source: CGImage, url: URL) -> ProjectionPhoto? {
        let width = source.width, height = source.height
        let longest = CGFloat(max(width, height))
        let feather = max(1.5, longest * 0.008)
        let radius = max(2, longest * 0.012)
        var alpha = [UInt8](repeating: 255, count: width * height)
        var illumination = alpha
        // Bake the lens falloff and aperture edge once, keeping the central
        // image unchanged. Animation only moves these completed rasters.
        for y in 0..<height {
            if y.isMultiple(of: 64), Task.isCancelled { return nil }
            let dy = min(CGFloat(y) + 0.5, CGFloat(height - y) - 0.5)
            for x in 0..<width {
                let dx = min(CGFloat(x) + 0.5, CGFloat(width - x) - 0.5)
                let nx = (CGFloat(x) + 0.5) * 2 / CGFloat(width) - 1
                let ny = (CGFloat(y) + 0.5) * 2 / CGFloat(height) - 1
                let falloff = min(1, max(0, (nx * nx + ny * ny - 0.55) / 1.45))
                illumination[y * width + x] = UInt8(((1 - 0.13 * falloff * falloff * (3 - 2 * falloff)) * 255).rounded())
                if dx >= radius && dy >= feather { continue }
                var distance = min(dx, dy)
                if dx < radius && dy < radius {
                    distance = radius - hypot(radius - dx, radius - dy)
                }
                let t = min(1, max(0, (distance - 0.5) / feather))
                alpha[y * width + x] = UInt8((t * t * (3 - 2 * t) * 255).rounded())
            }
        }
        func grayscale(_ bytes: [UInt8]) -> CGImage? {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let mask = grayscale(alpha), let falloff = grayscale(illumination) else { return nil }
        let input = CIImage(cgImage: source).applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: falloff)
        ])
        let extent = input.extent
        let transparent = CIImage(color: .clear).cropped(to: extent)
        let maskImage = CIImage(cgImage: mask)
        func masked(_ image: CIImage) -> CGImage? {
            let result = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: maskImage
            ])
            return context.createCGImage(result, from: extent, format: .RGBA8,
                                         colorSpace: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        }
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, longest * 0.0012)])
            .cropped(to: extent)
        guard let sharp = masked(input), let soft = masked(blurred), !Task.isCancelled else { return nil }
        // A small, cached colour spill surrounds the aperture. It is not a
        // full-screen glow and needs no live blur or steady animation clock.
        let scale = min(1, 500 / longest)
        let small = CIImage(cgImage: sharp).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let padding = (longest * scale * 0.10).rounded(.up)
        let glowExtent = small.extent.insetBy(dx: -padding, dy: -padding).integral
        let scattered = small.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, longest * scale * 0.025)])
        let glow = context.createCGImage(scattered, from: glowExtent, format: .RGBA8,
                                        colorSpace: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        return ProjectionPhoto(url: url, sharp: sharp, soft: soft, glow: glow,
                               glowOutset: padding / (longest * scale))
    }
}

@MainActor @Observable
final class SlideshowPlayback {
    typealias Loader = @MainActor (URL) async -> ProjectionPhoto?
    enum Phase { case waiting, departing, black, arriving, settled }
    private let loader: Loader
    private let outgoingSound: () -> Void
    private let firstArrivalSound: () -> Void
    private let prepareSound: () async -> Void
    private let stopSound: () -> Void
    private var task: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var arrivalTask: Task<Void, Never>?
    private var request = UUID()
    private var presentationReady = false
    private var reduceMotion = false
    private var sourceReady = false
    private var hasPresentedPhoto = false
    private(set) var phase = Phase.waiting
    private(set) var requestedURL: URL?
    private(set) var photo: ProjectionPhoto?
    private(set) var shutter = 0.0
    private(set) var focus = 1.0
    private(set) var transport = -1.0
    private(set) var loadingHint = false
    private(set) var failed = false

    init(loader: @escaping Loader = { await SlideshowProjectionStore.shared.photo($0) },
         outgoingSound: @escaping () -> Void = {}, firstArrivalSound: @escaping () -> Void = {},
         prepareSound: @escaping () async -> Void = {},
         stopSound: @escaping () -> Void = {}) {
        self.loader = loader
        self.outgoingSound = outgoingSound; self.prepareSound = prepareSound
        self.firstArrivalSound = firstArrivalSound
        self.stopSound = stopSound
    }

    func show(_ url: URL, reduceMotion: Bool) {
        task?.cancel(); hintTask?.cancel(); arrivalTask?.cancel()
        stopSound()
        // An interrupted moving slide must not jump back to the centre while
        // the next source loads. A settled slide can remain visible instead.
        if phase == .departing || phase == .arriving {
            closeShutter()
        }
        let id = UUID()
        request = id; requestedURL = url
        self.reduceMotion = reduceMotion
        failed = false; loadingHint = false; sourceReady = false
        hintTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let self, self.request == id else { return }
            self.loadingHint = true
        }
        task = Task { [weak self, loader, prepareSound] in
            // Prepare audio alongside the photo, before any visible movement.
            async let soundReady: Void = prepareSound()
            let value = await loader(url)
            await soundReady
            guard !Task.isCancelled, let self, self.request == id else { return }
            self.hintTask?.cancel(); self.loadingHint = false
            guard let value else {
                self.closeShutter()
                self.photo = nil; self.failed = true
                return
            }
            // Keep the settled old slide while decoding. Start the mechanics
            // only once data is ready so slow sources cannot outrun the sound.
            if self.presentationReady && self.phase == .settled && self.photo != nil {
                self.phase = .departing
                self.outgoingSound()
                if !reduceMotion {
                    withAnimation(.timingCurve(0.12, 0.80, 0.25, 1, duration: 0.08)) {
                        self.transport = 1
                    }
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                    guard !Task.isCancelled, self.request == id else { return }
                }
                self.closeShutter()
            }
            if self.presentationReady && self.phase == .black && !reduceMotion {
                // Let the single shutter recording continue through black.
                // Closing the aperture and arrival must not restart it.
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                guard !Task.isCancelled, self.request == id else { return }
            }
            // Replace the source only after the short, fully black interval.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                self.photo = value
                self.failed = false
                self.focus = reduceMotion ? 1 : 0
                self.transport = reduceMotion ? 0 : -1
                self.shutter = 0
                self.phase = .waiting
            }
            if !reduceMotion {
                // Commit the new, dark source before starting its reveal. A
                // single SwiftUI transaction would collapse focus 0 -> 1.
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, self.request == id else { return }
            }
            self.sourceReady = true
            if self.presentationReady { self.startArrival() }
        }
    }

    func beginPresentation() {
        guard !presentationReady else { return }
        presentationReady = true
        if sourceReady { startArrival() }
    }

    private func closeShutter() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            shutter = 0
            phase = .black
        }
    }

    private func startArrival() {
        guard presentationReady, sourceReady, phase == .waiting else { return }
        phase = .arriving
        if !hasPresentedPhoto {
            hasPresentedPhoto = true
            firstArrivalSound()
        }
        reveal()
        guard !reduceMotion else { phase = .settled; return }
        let id = request
        arrivalTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, !Task.isCancelled, self.request == id, self.presentationReady else { return }
            self.phase = .settled
        }
    }

    private func reveal() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.08)) { shutter = 1 }
        withAnimation(reduceMotion ? nil : .timingCurve(0.20, 0.65, 0.35, 1, duration: 0.18)) { transport = 0 }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { focus = 1 }
    }

    func cancel() {
        request = UUID()
        task?.cancel(); hintTask?.cancel(); arrivalTask?.cancel()
        task = nil; hintTask = nil; arrivalTask = nil
        stopSound()
        requestedURL = nil; photo = nil
        presentationReady = false; sourceReady = false; phase = .waiting
        hasPresentedPhoto = false
        shutter = 0; transport = -1; loadingHint = false; failed = false
    }

    func waitForPendingLoad() async { await task?.value; await arrivalTask?.value }
}
