import AppKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

final class PhotoPreview: @unchecked Sendable {
    /// Unmodified, oriented preview for comparisons; never written back to disk.
    let source: CGImage
    /// Steady transmitted light with localized spill around existing bright apertures.
    let lit: CGImage
    let dark: CGImage
    /// Highlight-only switch-on halo, screened over a stable exposure.
    let flare: CGImage
    /// Stronger cached scatter; linear lamp gain is applied at display time.
    let boosted: CGImage
    let transmitted: Bool

    /// Pre-decoded CIImage layers to avoid repeated PNG decompression during animation.
    let sourceCIImage: CIImage
    let litCIImage: CIImage
    let darkCIImage: CIImage
    let flareCIImage: CIImage
    let boostedCIImage: CIImage

    init(source: CGImage, lit: CGImage, dark: CGImage, flare: CGImage, boosted: CGImage? = nil, transmitted: Bool = true) {
        self.source = source; self.lit = lit; self.dark = dark; self.flare = flare
        self.boosted = boosted ?? lit; self.transmitted = transmitted
        self.sourceCIImage = CIImage(cgImage: source)
        self.litCIImage = CIImage(cgImage: lit)
        self.darkCIImage = CIImage(cgImage: dark)
        self.flareCIImage = CIImage(cgImage: flare)
        self.boostedCIImage = CIImage(cgImage: boosted ?? lit)
    }

    private init(source: CGImage, lit: CGImage, dark: CGImage, flare: CGImage, boosted: CGImage,
                 sourceCIImage: CIImage, litCIImage: CIImage, darkCIImage: CIImage,
                 flareCIImage: CIImage, boostedCIImage: CIImage, transmitted: Bool) {
        self.source = source; self.lit = lit; self.dark = dark; self.flare = flare; self.boosted = boosted
        self.sourceCIImage = sourceCIImage; self.litCIImage = litCIImage; self.darkCIImage = darkCIImage
        self.flareCIImage = flareCIImage; self.boostedCIImage = boostedCIImage
        self.transmitted = transmitted
    }

    var aspect: CGFloat { CGFloat(lit.width) / CGFloat(lit.height) }

    /// A cheap reference selection shared by the canvas, album and lens.
    /// Original mode is the source preview at steady 100% lamp brightness.
    func viewing(transmitted: Bool) -> PhotoPreview {
        if transmitted == self.transmitted { return self }
        if transmitted {
            return PhotoPreview(source: source, lit: lit, dark: dark, flare: flare, boosted: boosted,
                              sourceCIImage: sourceCIImage, litCIImage: litCIImage, darkCIImage: darkCIImage,
                              flareCIImage: flareCIImage, boostedCIImage: boostedCIImage, transmitted: true)
        } else {
            return PhotoPreview(source: source, lit: source, dark: dark, flare: flare, boosted: boosted,
                              sourceCIImage: sourceCIImage, litCIImage: sourceCIImage, darkCIImage: darkCIImage,
                              flareCIImage: flareCIImage, boostedCIImage: boostedCIImage, transmitted: false)
        }
    }
}

/// Bounded previews only; no source image is ever written or re-encoded.
actor PhotoStore {
    static let shared = PhotoStore()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let cacheDirectory: URL
    private struct PreviewKey: Hashable { let url: URL; let maxPixel: Int }
    private var cache: [PreviewKey: PhotoPreview] = [:]
    private var recent: [PreviewKey] = []

    init(cacheDirectory: URL = PhotoPreviewDiskCache.directory) {
        self.cacheDirectory = cacheDirectory
    }

    func preview(_ url: URL, maxPixel: Int = 2200) -> PhotoPreview? {
        let key = PreviewKey(url: url, maxPixel: min(2200, max(128, maxPixel)))
        if let value = cache[key] { touch(key); return value }
        if let value = PhotoPreviewDiskCache.load(url, maxPixel: key.maxPixel, root: cacheDirectory) {
            cache[key] = value; touch(key)
            return value
        }
        guard let source = decode(url, maxPixel: key.maxPixel) else { return nil }
        // A positive transparency viewed by weak reflected room light. All
        // channels retain their hue; a tiny neutral reflection remains on black.
        let input = CIImage(cgImage: source)
        let darkCI = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(input.extent.width, input.extent.height) * 0.0015])
            .cropped(to: input.extent)
            .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.032, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.032, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.032, w: 0),
            "inputBiasVector": CIVector(x: 0.0015, y: 0.0015, z: 0.0015, w: 0)
        ])
        guard let dark = context.createCGImage(darkCI, from: input.extent,
                                               format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        guard let lit = renderTransmission(input, boosted: false),
              let boosted = renderTransmission(input, boosted: true),
              let flare = renderSwitchOnHalo(input) else { return nil }
        let value = PhotoPreview(source: source, lit: lit, dark: dark, flare: flare, boosted: boosted)
        PhotoPreviewDiskCache.save(value, for: url, maxPixel: key.maxPixel, root: cacheDirectory)
        cache[key] = value; touch(key)
        return value
    }

    /// Existing bright apertures emit a tight rim plus a faint, wider diffusion.
    /// Scatter is evaluated once in source coordinates, not while moving the lens.
    /// Keep the source sharp: only the emitted light is blurred. Nearby opaque
    /// film can receive optical scatter; distant blacks and midtones stay intact.
    private func renderTransmission(_ input: CIImage, boosted: Bool) -> CGImage? {
        let highlights = Self.cube(input, data: Self.highlightCube)
        let dimension = max(input.extent.width, input.extent.height)
        let rim = outwardScatter(highlights, radius: dimension * (boosted ? 0.0045 : 0.0035),
                                 strength: boosted ? 0.24 : 0.09)
        let diffusion = outwardScatter(highlights, radius: dimension * (boosted ? 0.014 : 0.011),
                                       strength: boosted ? 0.085 : 0.025)
        let transmitted = diffusion.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: rim.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: input
            ])
        ])
        return context.createCGImage(transmitted, from: input.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    private func outwardScatter(_ highlights: CIImage, radius: Double, strength: Double) -> CIImage {
        let blurred = highlights.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, radius)])
            .cropped(to: highlights.extent)
        // Core Image subtract blend is background - foreground. Retain only
        // outward light, so bright interiors don't dim or lose their gradation.
        return highlights.applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: blurred
        ])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    private func renderSwitchOnHalo(_ input: CIImage) -> CGImage? {
        // At ignition the light briefly spreads farther from existing apertures;
        // the shared light clock clears this excess, leaving the steady soft rim.
        // Keep source exposure fixed and retain the protected highlight core.
        let dimension = max(input.extent.width, input.extent.height)
        let radius = dimension * 0.0035
        let core = Self.cube(input, data: Self.switchOnHighlightCube).clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.8, radius)])
            .cropped(to: input.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.22, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.22, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.22, w: 0)
            ])
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: input.extent),
                kCIInputMaskImageKey: Self.cube(input, data: Self.blackProtectionCube)
            ])
        let spread = outwardScatter(Self.cube(input, data: Self.highlightCube),
                                    radius: dimension * 0.012, strength: 0.065)
        let halo = spread.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: core
        ])
        return context.createCGImage(halo, from: input.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    private static let cubeDimension = 32
    private static let cubeSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private static let highlightCube = makeCube { r, g, b in
        let mask = smoothstep(0.60, 0.92, luminance(r, g, b))
        return (r * mask, g * mask, b * mask)
    }
    private static let switchOnHighlightCube = makeCube { r, g, b in
        let mask = smoothstep(0.50, 0.90, luminance(r, g, b))
        return (r * mask, g * mask, b * mask)
    }
    private static let blackProtectionCube = makeCube { r, g, b in
        let mask = smoothstep(0.004, 0.075, luminance(r, g, b))
        return (mask, mask, mask)
    }

    private static func cube(_ image: CIImage, data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeDimension,
            "inputCubeData": data,
            "inputColorSpace": cubeSpace
        ])
    }

    private static func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.228975 * r + 0.691739 * g + 0.079287 * b
    }

    private static func smoothstep(_ start: Float, _ end: Float, _ value: Float) -> Float {
        let t = min(1, max(0, (value - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    private static func makeCube(_ transform: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var values = [Float]()
        values.reserveCapacity(cubeDimension * cubeDimension * cubeDimension * 4)
        let divisor = Float(cubeDimension - 1)
        for b in 0..<cubeDimension {
            for g in 0..<cubeDimension {
                for r in 0..<cubeDimension {
                    let color = transform(Float(r) / divisor, Float(g) / divisor, Float(b) / divisor)
                    values.append(contentsOf: [color.0, color.1, color.2, 1])
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func thumbnail(_ url: URL) async -> CGImage? {
        await PhotoThumbnails.shared.thumbnail(url)
    }

    private func touch(_ url: PreviewKey) {
        recent.removeAll { $0 == url }; recent.append(url)
        // Disk hits and newly rendered previews obey the same memory limit.
        while recent.count > 12 { cache.removeValue(forKey: recent.removeFirst()) }
    }

    private func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Reuses the expensive, derived optical layers between launches. Cache identity
/// includes source metadata and the rendering recipe; originals are never touched.
enum PhotoPreviewDiskCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("OurLightTable/previews-v2", isDirectory: true)
    private static let recipe = "transmission-scatter-2"
    private static let layerNames = ["source", "lit", "dark", "flare", "boosted"]

    private static func folder(_ url: URL, maxPixel: Int, root: URL) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        let identity = "\(recipe)|\(url.standardizedFileURL.path)|\(date.timeIntervalSince1970)|\(size)|\(maxPixel)"
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash, isDirectory: true)
    }

    static func load(_ url: URL, maxPixel: Int, root: URL = directory) -> PhotoPreview? {
        guard let folder = folder(url, maxPixel: maxPixel, root: root) else { return nil }
        func image(_ name: String) -> CGImage? {
            let file = folder.appendingPathComponent(name).appendingPathExtension("png")
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let source = image("source"), let lit = image("lit"), let dark = image("dark"),
              let flare = image("flare"), let boosted = image("boosted") else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return PhotoPreview(source: source, lit: lit, dark: dark, flare: flare, boosted: boosted)
    }

    static func save(_ preview: PhotoPreview, for url: URL, maxPixel: Int, root: URL = directory) {
        guard let folder = folder(url, maxPixel: maxPixel, root: root) else { return }
        let fm = FileManager.default
        do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return }
        for (name, image) in zip(layerNames, [preview.source, preview.lit, preview.dark, preview.flare, preview.boosted]) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { continue }
            try? (data as Data).write(to: folder.appendingPathComponent(name).appendingPathExtension("png"), options: .atomic)
        }
        trim(root: root, keeping: folder)
    }

    private static func trim(root: URL, keeping current: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]) else { return }
        var folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var total = folders.reduce(Int64(0)) { sum, folder in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return sum + files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        folders.sort {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        while (folders.count > 48 || total > 750 * 1024 * 1024), let oldest = folders.first, oldest != current {
            let size = ((try? fm.contentsOfDirectory(at: oldest, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            try? fm.removeItem(at: oldest)
            total -= size
            folders.removeFirst()
        }
    }
}

/// Thumbnails must never wait behind full-size optical processing on PhotoStore.
actor PhotoThumbnails {
    static let shared = PhotoThumbnails()
    private var images: [String: CGImage] = [:]
    private var order: [String] = []

    func thumbnail(_ url: URL) -> CGImage? {
        guard let key = PhotoThumbnailCache.key(url) else { return nil }
        if let image = images[key] { return image }
        let image: CGImage
        if let cached = PhotoThumbnailCache.cached(url) { image = cached }
        else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 220,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            image = decoded
            PhotoThumbnailCache.save(image, for: url)
        }
        images[key] = image; order.append(key)
        while order.count > 300 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}

/// Lossless, disposable startup images. Source bytes and saved layouts are untouched.
/// Modification time and file size invalidate a cached thumbnail after an edit.
enum PhotoThumbnailCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("OurLightTable/thumbnails-v1", isDirectory: true)

    static func key(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        let identity = "\(url.standardizedFileURL.path)|\(date.timeIntervalSince1970)|\(size)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func cached(_ url: URL, directory root: URL = directory) -> CGImage? {
        guard let key = key(url),
              let source = CGImageSourceCreateWithURL(root.appendingPathComponent(key).appendingPathExtension("png") as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func save(_ image: CGImage, for url: URL, directory root: URL = directory) {
        guard let key = key(url) else { return }
        let fm = FileManager.default
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? (data as Data).write(to: root.appendingPathComponent(key).appendingPathExtension("png"), options: .atomic)
        // Bound only this disposable cache, never the user's image directory.
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 320 else { return }
        let oldest = files.filter { $0.pathExtension == "png" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in oldest.prefix(max(0, oldest.count - 300)) { try? fm.removeItem(at: file) }
    }
}

struct Photo: Identifiable, Equatable, Sendable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum PhotoLibrary {
    /// Read oriented geometry without decoding a full photo or preparing lighting.
    static func imageAspect(_ url: URL) -> Double {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return 1.5 }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? height.doubleValue / width.doubleValue : width.doubleValue / height.doubleValue
    }

    /// Only aliases created by the old SwiftUI NSURL drag path are eligible.
    /// Genuine same-named files in other folders always remain distinct photos.
    static func legacyDragAliases(in urls: [URL], cacheDirectory: URL? = nil) -> [URL: URL] {
        let cacheRoot = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let cacheRoot else { return [:] }
        var seen = Set<URL>()
        let files = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        let originals = files.filter { !isLegacyDragCache($0, cacheRoot: cacheRoot) && supported($0) }
        let byName = Dictionary(grouping: originals, by: \.lastPathComponent)
        var result: [URL: URL] = [:]
        for cached in files where isLegacyDragCache(cached, cacheRoot: cacheRoot) && supported(cached) {
            for original in (byName[cached.lastPathComponent] ?? []) {
                guard (try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize) ==
                      (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize),
                      FileManager.default.contentsEqual(atPath: cached.path, andPath: original.path) else { continue }
                result[cached] = original
                break
            }
        }
        return result
    }

    private static func isLegacyDragCache(_ url: URL, cacheRoot: URL) -> Bool {
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        let prefix = "com.apple.SwiftUI.Drag-"
        return directory.deletingLastPathComponent().standardizedFileURL == cacheRoot.standardizedFileURL &&
               directory.lastPathComponent.hasPrefix(prefix) &&
               UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil
    }

    static func supported(_ url: URL) -> Bool {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else { return false }
        return true
    }

    static func scan(_ inputs: [URL]) -> [URL] {
        var result = Set<URL>()
        for url in inputs where url.isFileURL {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                guard let files = FileManager.default.enumerator(at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in files where supported(file) {
                    result.insert(file.standardizedFileURL)
                }
            } else if supported(url) { result.insert(url.standardizedFileURL) }
        }
        return result.sorted { a, b in
            let order = a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
            return order == .orderedSame ? a.path < b.path : order == .orderedAscending
        }
    }
}
