import AppKit
import CoreImage
import MetalKit
import os
import SwiftUI

/// Color-managed output; redraws when image, light, size or EDR capacity changes.
struct OpticalDisplay: NSViewRepresentable {
    var preview: PhotoPreview? = nil
    var image: CGImage? = nil
    var loupe: LoupeDisplayInput? = nil
    var transmission: Double = 1
    var flare: Double = 0
    var brightness: Double = 1
    var edrEnabled = false
    func makeNSView(context: Context) -> OpticalMetalView { OpticalMetalView() }
    func updateNSView(_ view: OpticalMetalView, context: Context) {
        view.set(preview: preview, image: image, transmission: transmission,
                 flare: flare, brightness: brightness, loupe: loupe, edrEnabled: edrEnabled)
    }
}

/// Bounded recovery after a visible surface fails to draw. The delays only
/// pace failure retries; ordinary input still redraws immediately.
struct OpticalRetryBudget {
    private(set) var revision = 0
    private(set) var attempts = 0

    mutating func beginNewInput() {
        revision &+= 1
        attempts = 0
    }

    mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [1.0 / 60.0, 0.05, 0.15]
        guard attempts < delays.count else { return nil }
        let delay = delays[attempts]
        attempts += 1
        return delay
    }

    mutating func succeeded() {
        attempts = 0
    }
}

struct OpticalFrameGate {
    private(set) var inFlight = false
    private(set) var needsRedraw = false

    mutating func deferLatestFrame() -> Bool {
        guard inFlight else { return false }
        needsRedraw = true
        return true
    }

    mutating func begin() {
        inFlight = true
    }

    mutating func finish() -> Bool {
        inFlight = false
        defer { needsRedraw = false }
        return needsRedraw
    }
}

enum OpticalPresentationPolicy {
    static func waitsForScheduling(edrLoupe: Bool) -> Bool { !edrLoupe }
}

final class OpticalMetalView: MTKView {
    static let gpu = MTLCreateSystemDefaultDevice()
    private static let queue = gpu?.makeCommandQueue()
    private static let renderer: CIContext? = gpu.map { CIContext(mtlDevice: $0, options: [
        .workingColorSpace: PhotoOptics.linearSpace, .cacheIntermediates: false]) }
    private static let edrRenderer = PhotoOptics.edrRenderer
    private static let pending = NSHashTable<OpticalMetalView>.weakObjects()
    private static var scheduled = false
    private static let log = Logger(subsystem: "local.ourlighttable.desktop", category: "OpticalDisplay")
    /// Injectable so checks can drive retries without a window or a real timer.
    static var scheduleRetry: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var preview: PhotoPreview?
    private var image: CGImage?
    private(set) var loupe: LoupeDisplayInput?
    private let loupeTextureCache: LoupeTextureCache?
    private lazy var loupeRenderer = LoupeRenderer(textureCache: loupeTextureCache)
    private var transmission = 1.0
    private var flare = 0.0
    private var brightness = 1.0
    private var edrEnabled = false
    private let headroomProvider: (NSScreen?) -> Double
    private var currentEDRHeadroom = 1.0

    // Cache the finished display pixels. Animation never reads this texture
    // back into Core Image, so every light state has the same orientation.
    private(set) var cachedStableTexture: MTLTexture?
    private var cachedStableParams: CacheParams?
    private var cacheBuildInFlight = false
    private var cacheGeneration = 0

    // Failure recovery: at most one live deferred redraw per view, tied to
    // the input revision that failed.
    private(set) var retry = OpticalRetryBudget()
    private(set) var pendingRetry: Int?
    private var retryToken = 0
    private var exhaustedRevision: Int?
    private var drawnSize = CGSize.zero
    private var edrLoupeFrameGate = OpticalFrameGate()

    private struct CacheParams: Equatable {
        let source: ObjectIdentifier
        let lit: ObjectIdentifier
        let dark: ObjectIdentifier
        let flare: ObjectIdentifier
        let boosted: ObjectIdentifier
        let transmitted: Bool
        let brightness: Double
        let edrEnabled: Bool
        let edrHeadroom: Double

        init?(preview: PhotoPreview?, brightness: Double, edrEnabled: Bool, edrHeadroom: Double) {
            guard let preview else { return nil }
            source = ObjectIdentifier(preview.source)
            lit = ObjectIdentifier(preview.lit)
            dark = ObjectIdentifier(preview.dark)
            flare = ObjectIdentifier(preview.flare)
            boosted = ObjectIdentifier(preview.boosted)
            transmitted = preview.transmitted
            self.brightness = brightness
            self.edrEnabled = edrEnabled
            self.edrHeadroom = edrHeadroom
        }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(loupeTextureCache: LoupeTextureCache? = .shared,
         headroomProvider: @escaping (NSScreen?) -> Double = {
             Double($0?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
         }) {
        self.loupeTextureCache = loupeTextureCache
        self.headroomProvider = headroomProvider
        super.init(frame: .zero, device: Self.gpu)
        colorPixelFormat = .bgra8Unorm
        colorspace = PhotoOptics.blendSpace
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        (layer as? CAMetalLayer)?.isOpaque = false
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
        (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = false
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
            name: NSWindow.didChangeScreenNotification, object: nil)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func screenParametersChanged(_ notification: Notification) {
        if let changedWindow = notification.object as? NSWindow, changedWindow !== window { return }
        if refreshEDRHeadroom() { needsDisplay = true }
    }

    @discardableResult
    private func refreshEDRHeadroom() -> Bool {
        let headroom = edrEnabled ? PhotoOptics.boundedEDRHeadroom(headroomProvider(window?.screen)) : 1
        guard headroom != currentEDRHeadroom else { return false }
        currentEDRHeadroom = headroom
        invalidateCache()
        beginNewInput()
        return true
    }

    private func invalidateCache() {
        cacheGeneration += 1
        cachedStableTexture = nil
        cachedStableParams = nil
        cacheBuildInFlight = false
    }

    private func beginNewInput() {
        retry.beginNewInput()
        cancelRetry()
    }

    private func cancelRetry() {
        retryToken &+= 1
        pendingRetry = nil
    }

    /// A visible surface could not produce a frame; preserve the input and
    /// schedule a bounded redraw for this input revision.
    func noteDrawFailure(_ reason: String) {
        guard pendingRetry == nil else { return }
        let revision = retry.revision
        guard let delay = retry.nextDelay() else {
            if exhaustedRevision != revision {
                exhaustedRevision = revision
                Self.log.error("Optical surface retries exhausted: \(reason, privacy: .public)")
            }
            return
        }
        if retry.attempts == 1 {
            Self.log.debug("Optical surface draw failed: \(reason, privacy: .public)")
        }
        retryToken &+= 1
        let token = retryToken
        pendingRetry = token
        Self.scheduleRetry(delay) { [weak self] in self?.retryFired(token: token, revision: revision) }
    }

    /// Called after the GPU completed this input's frame.
    func noteDrawSuccess() {
        retry.succeeded()
        cancelRetry()
    }

    private func retryFired(token: Int, revision: Int) {
        guard pendingRetry == token, retry.revision == revision else { return }
        pendingRetry = nil
        // Detached views wait for the next window or size event instead of polling.
        guard window != nil else { return }
        needsDisplay = true
    }

    func set(preview: PhotoPreview?, image: CGImage?, transmission: Double,
             flare: Double, brightness: Double, loupe: LoupeDisplayInput? = nil,
             edrEnabled: Bool = false) {
        let edrChanged = self.edrEnabled != edrEnabled
        if edrChanged {
            self.edrEnabled = edrEnabled
            colorPixelFormat = edrEnabled ? .rgba16Float : .bgra8Unorm
            colorspace = edrEnabled ? PhotoOptics.linearSpace : PhotoOptics.blendSpace
            (layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = edrEnabled
            (layer as? CAMetalLayer)?.colorspace = colorspace
            invalidateCache()
        }
        let sourceChanged = self.preview?.source !== preview?.source || self.preview?.lit !== preview?.lit ||
            self.preview?.dark !== preview?.dark || self.preview?.boosted !== preview?.boosted ||
            self.preview?.flare !== preview?.flare || self.preview?.transmitted != preview?.transmitted ||
            self.image !== image || self.brightness != brightness || self.loupe != loupe
        let changed = sourceChanged || self.transmission != transmission || self.flare != flare || edrChanged
        if sourceChanged { invalidateCache() }

        self.preview = preview; self.image = image; self.transmission = transmission
        self.flare = flare; self.brightness = brightness; self.loupe = loupe
        let shouldAutoResize = loupe == nil
        if autoResizeDrawable != shouldAutoResize { autoResizeDrawable = shouldAutoResize }
        if let loupe, drawableSize != loupe.pixelSize {
            // Rasterize the visible viewport at its current Retina resolution.
            drawableSize = loupe.pixelSize
        }
        if changed { beginNewInput(); needsDisplay = true }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCache()
        beginNewInput()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateCache()
        beginNewInput()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) { enqueue() }

    private func enqueue() {
        Self.pending.add(self)
        guard !Self.scheduled else { return }
        Self.scheduled = true
        // SwiftUI updates every surface before encoding the group together.
        DispatchQueue.main.async { Self.drawPending() }
    }

    private struct EncodedSurface {
        weak var view: OpticalMetalView?
        let revision: Int
        let size: CGSize
        let edrLoupe: Bool
    }

    private enum LiveEncode {
        case idle
        case failed(String)
        case encoded(CAMetalDrawable)
    }

    private var isPresentable: Bool {
        guard let window, let screen = window.screen, window.frame.intersects(screen.frame) else { return false }
        return visibleRect.width > 0 && visibleRect.height > 0
    }

    private static func drawPending() {
        scheduled = false
        let views = pending.allObjects
        pending.removeAllObjects()
        guard let renderer else { return }
        // Hidden, windowless or offscreen views wait for a later display event.
        let visible = views.filter(\.isPresentable)
        drawVisible(visible, renderer: renderer, makeCommandBuffer: { queue?.makeCommandBuffer() })
    }

    /// The caller has checked visibility. Injecting only buffer allocation lets
    /// checks exercise allocation failure without a window or GPU exhaustion.
    static func drawVisible(_ views: [OpticalMetalView], renderer: CIContext,
                            makeCommandBuffer: () -> MTLCommandBuffer?) {
        // Sync size and retry revision before any allocation can fail. Idle
        // surfaces must not consume a retry when the whole batch lacks a buffer.
        let visible = views.filter { $0.prepareDraw() }
        guard !visible.isEmpty else { return }
        guard let buffer = makeCommandBuffer() else {
            for view in visible { view.noteDrawFailure("command buffer unavailable") }
            return
        }
        var drawables: [CAMetalDrawable] = []
        var encoded: [EncodedSurface] = []
        for view in visible {
            switch view.encode(into: buffer, renderer: renderer) {
            case .idle: continue
            case .failed(let reason): view.noteDrawFailure(reason)
            case .encoded(let drawable):
                let edrLoupe = view.edrEnabled && view.loupe != nil
                if edrLoupe { view.edrLoupeFrameGate.begin() }
                drawables.append(drawable)
                encoded.append(EncodedSurface(view: view, revision: view.retry.revision,
                                              size: view.drawableSize, edrLoupe: edrLoupe))
            }
        }
        guard !drawables.isEmpty else { return }
        buffer.addCompletedHandler { completed in
            let succeeded = completed.status == .completed
            DispatchQueue.main.async {
                for surface in encoded {
                    guard let view = surface.view else { continue }
                    if surface.edrLoupe {
                        let changedWhileRendering = view.edrLoupeFrameGate.finish()
                        if changedWhileRendering || view.retry.revision != surface.revision ||
                            view.drawableSize != surface.size {
                            view.needsDisplay = true
                        }
                    }
                    // A newer input or drawable size owns the view's retry state now.
                    guard view.retry.revision == surface.revision,
                          view.drawableSize == surface.size else { continue }
                    if succeeded { view.noteDrawSuccess() } else { view.noteDrawFailure("GPU command buffer failed") }
                }
            }
        }
        let hasEDRLoupe = encoded.contains(where: \.edrLoupe)
        if OpticalPresentationPolicy.waitsForScheduling(edrLoupe: hasEDRLoupe) {
            // Transaction-synchronized table surfaces retain their coordinated presentation.
            buffer.commit()
            buffer.waitUntilScheduled()
            guard buffer.status != .error else { return }
            for drawable in drawables { drawable.present() }
        } else {
            // EDR loupe graphs are expensive to schedule. Queue presentation
            // before commit so pointer input never waits for GPU scheduling on the main thread.
            for drawable in drawables { drawable.present() }
            buffer.commit()
        }
    }

    private func prepareDraw() -> Bool {
        refreshEDRHeadroom()
        guard drawableSize.width > 0, drawableSize.height > 0,
              preview != nil || image != nil || loupe != nil else { return false }
        if edrEnabled, loupe != nil, edrLoupeFrameGate.deferLatestFrame() { return false }
        if drawableSize != drawnSize { drawnSize = drawableSize; beginNewInput() }
        return true
    }

    private func encode(into buffer: MTLCommandBuffer, renderer: CIContext) -> LiveEncode {
        guard window != nil, drawableSize.width > 0, drawableSize.height > 0,
              preview != nil || image != nil || loupe != nil else { return .idle }
        guard let drawable = (layer as? CAMetalLayer)?.nextDrawable() else { return .failed("drawable unavailable") }
        guard encode(into: drawable.texture, commandBuffer: buffer, renderer: renderer) else { return .failed("encoding failed") }
        return .encoded(drawable)
    }

    /// Shared by the live drawable and GPU regression checks. Cache only a
    /// fully rendered stable frame; do not generate a second image on first draw.
    @discardableResult
    func encode(into texture: MTLTexture, commandBuffer buffer: MTLCommandBuffer, renderer: CIContext) -> Bool {
        refreshEDRHeadroom()
        let headroom = currentEDRHeadroom
        let isStable = flare == 0 && transmission == 1
        let params = CacheParams(preview: preview, brightness: brightness,
                                 edrEnabled: edrEnabled, edrHeadroom: headroom)
        let canCache = isStable && loupe == nil && params != nil
        if canCache, let cached = cachedStableTexture, cachedStableParams == params,
           cached.width == texture.width, cached.height == texture.height,
           cached.pixelFormat == texture.pixelFormat, let encoder = buffer.makeBlitCommandEncoder() {
            encoder.copy(from: cached, sourceSlice: 0, sourceLevel: 0,
                         to: texture, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
            encoder.endEncoding()
            return true
        }

        let size = CGSize(width: texture.width, height: texture.height)
        guard let input = composedInput(edrHeadroom: headroom), let fitted = fitted(input, to: size) else { return false }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        destination.colorSpace = edrEnabled ? PhotoOptics.linearSpace : PhotoOptics.blendSpace
        destination.isFlipped = true
        let activeRenderer = edrEnabled ? (Self.edrRenderer ?? renderer) : renderer
        do { _ = try activeRenderer.startTask(toRender: fitted, to: destination) }
        catch { return false }

        if canCache, !cacheBuildInFlight,
           let cache = makeCacheTexture(width: texture.width, height: texture.height),
           let encoder = buffer.makeBlitCommandEncoder() {
            encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                         to: cache, destinationSlice: 0, destinationLevel: 0, sliceCount: 1, levelCount: 1)
            encoder.endEncoding()
            cacheBuildInFlight = true
            let generation = cacheGeneration
            buffer.addCompletedHandler { [weak self] completed in
                let succeeded = completed.status == .completed
                DispatchQueue.main.async {
                    guard let self, self.cacheGeneration == generation else { return }
                    self.cacheBuildInFlight = false
                    guard succeeded else { return }
                    self.cachedStableTexture = cache
                    self.cachedStableParams = params
                }
            }
        }
        return true
    }

    private func makeCacheTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        return Self.gpu?.makeTexture(descriptor: descriptor)
    }

    private func fitted(_ image: CIImage, to size: CGSize) -> CIImage? {
        guard image.extent.width > 0, image.extent.height > 0,
              size.width > 0, size.height > 0 else { return nil }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width,
                                               y: size.height / image.extent.height))
    }

    /// Read the latest immutable input at encoding time.
    func composedInput() -> CIImage? {
        refreshEDRHeadroom()
        return composedInput(edrHeadroom: currentEDRHeadroom)
    }

    private func composedInput(edrHeadroom: Double) -> CIImage? {
        if let loupe {
            let scene = loupe.scene
            return loupeRenderer.composite(photos: scene.photos, point: scene.point,
                panelBounds: scene.panelBounds, diameter: loupe.diameter, magnification: loupe.magnification,
                displayScale: loupe.displayScale, transmission: scene.transmission, flare: scene.flare,
                brightness: scene.brightness, viewport: loupe.viewport, refractionScale: loupe.refractionScale,
                edrEnabled: scene.edrEnabled, edrHeadroom: edrHeadroom)
        } else if let preview {
            return PhotoOptics.composite(preview: preview, transmission: transmission,
                flare: flare, brightness: brightness, edrEnabled: edrEnabled, edrHeadroom: edrHeadroom)
        } else if let image {
            return CIImage(cgImage: image)
        }
        return nil
    }
}
