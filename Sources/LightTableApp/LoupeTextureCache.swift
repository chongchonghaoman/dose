import CoreImage
import Foundation
import MetalKit

/// Native-resolution source textures for stable EDR. Color math and glass remain live.
/// A miss never waits for the worker: the caller renders the original CI graph.
final class LoupeTextureCache {
    static let shared = LoupeTextureCache()

    private struct Key: Hashable {
        // Retain the actual image so a recycled object address cannot be a hit.
        let source: CGImage
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.source === rhs.source }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(source)) }
        var inputBytes: Int { source.bytesPerRow * source.height }
        var reservedBytes: Int { inputBytes + source.width * source.height * 4 }
    }

    private struct Entry {
        let image: CIImage
        let bytes: Int
    }
    struct Statistics {
        var hits = 0
        var misses = 0
        var builds = 0
        var failures = 0
        var evictions = 0
        var pending = 0
        var residentBytes = 0
        var reservedBytes = 0
        var entries = 0
    }

    let byteLimit: Int
    private let device: MTLDevice?
    private let worker = DispatchQueue(label: "local.ourlighttable.loupe-textures", qos: .utility)
    // Synchronous loading stays on this utility worker, never pointer input.
    private lazy var loader = device.map { MTKTextureLoader(device: $0) }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var recent: [Key] = []
    private var pending = Set<Key>()
    // Allocation failures must not restart an upload on every pointer event.
    // IDs only: failed sources are not retained outside the memory budget.
    private var failedUntil: [ObjectIdentifier: TimeInterval] = [:]
    private var counts = Statistics()

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), byteLimit: Int = 128 * 1024 * 1024) {
        self.device = device
        self.byteLimit = max(0, byteLimit)
    }

    var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        var result = counts
        result.pending = pending.count
        result.entries = entries.count
        return result
    }

    func image(preview: PhotoPreview, transmission: Double, flare: Double,
               brightness: Double, edrEnabled: Bool, edrHeadroom: Double = 1) -> CIImage? {
        // Do not turn ignition/slider animation into a backlog of obsolete work.
        // Above 100%, mixing boosted scatter before the nonlinear shoulder
        // amplifies texture/CGImage sampling differences. Keep the original CI
        // inputs there. Precompiled EDR also needs the original CI input:
        // alternate texture sampling differs on rotated fine detail.
        guard edrEnabled, transmission == 1, flare == 0, brightness.isFinite,
              brightness <= 1, PhotoOptics.boundedEDRHeadroom(edrHeadroom) <= 1,
              device != nil else { return nil }
        let lit = sourceImage(preview.lit)
        guard let lit else { return nil }
        // Preserve .95's sample -> color conversion -> light response order.
        // Baking the response into a linear texture before scaling changes edges.
        return PhotoOptics.composite(preview: preview, transmission: transmission, flare: flare,
            brightness: brightness, edrEnabled: true, edrHeadroom: edrHeadroom,
            litImage: lit)
    }

    private func sourceImage(_ source: CGImage) -> CIImage? {
        // PhotoStore normalizes previews to 8-bit sRGB. Other formats keep the
        // original CI path instead of silently changing profile or precision.
        let key = Key(source: source)
        // Existing ImageIO straight/opaque inputs already render efficiently.
        // An extra texture changes their premultiplication/sampling order and
        // showed no benefit in the disk-reload benchmark. Keep their CI path.
        guard source.colorSpace?.name == CGColorSpace.sRGB,
              source.alphaInfo == .premultipliedLast || source.alphaInfo == .premultipliedFirst,
              source.bitsPerComponent == 8, source.bitsPerPixel == 32,
              source.width > 0, source.height > 0, source.width <= 4096, source.height <= 4096,
              key.reservedBytes <= byteLimit else { return nil }
        lock.lock()
        if let entry = entries[key] {
            counts.hits += 1
            recent.removeAll { $0 == key }
            recent.append(key)
            lock.unlock()
            return entry.image
        }
        counts.misses += 1
        let identifier = ObjectIdentifier(source)
        let now = ProcessInfo.processInfo.systemUptime
        guard (failedUntil[identifier] ?? 0) <= now else { lock.unlock(); return nil }
        // Two queued requests at most; only one is submitted to the GPU at a time.
        guard pending.count < 2, !pending.contains(key),
              counts.reservedBytes + key.reservedBytes <= byteLimit else {
            lock.unlock()
            return nil
        }
        evict(untilAdding: key.reservedBytes)
        pending.insert(key)
        counts.reservedBytes += key.reservedBytes
        lock.unlock()
        worker.async { [self] in
            autoreleasepool { build(key) }
        }
        return nil
    }

    private func build(_ key: Key) {
        guard let loader else { finish(key, image: nil, textureBytes: 0); return }
        do {
            // The synchronous loader returns a fully initialized texture. Keep
            // encoded samples in a non-sRGB texture; CI performs the same color
            // conversion after sampling as it does for the original CGImage.
            let texture = try loader.newTexture(cgImage: key.source, options: [
                .SRGB: false, .origin: MTKTextureLoader.Origin.bottomLeft,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .generateMipmaps: false])
            let image = CIImage(mtlTexture: texture, options: [.colorSpace: PhotoOptics.blendSpace])
            finish(key, image: image, textureBytes: max(texture.allocatedSize, texture.width * texture.height * 4))
        } catch {
            finish(key, image: nil, textureBytes: 0)
        }
    }

    // Called with lock held. Reserved builds are included in the budget.
    private func evict(untilAdding bytes: Int) {
        while counts.residentBytes + counts.reservedBytes + bytes > byteLimit,
              let oldest = recent.first {
            recent.removeFirst()
            if let entry = entries.removeValue(forKey: oldest) {
                counts.residentBytes -= entry.bytes
                counts.evictions += 1
            }
        }
    }

    private func finish(_ key: Key, image: CIImage?, textureBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        pending.remove(key)
        counts.reservedBytes -= key.reservedBytes
        let bytes = key.inputBytes + textureBytes
        guard let image, bytes + counts.reservedBytes <= byteLimit else {
            counts.failures += 1
            let now = ProcessInfo.processInfo.systemUptime
            failedUntil = failedUntil.filter { $0.value > now }
            if failedUntil.count >= 8, let oldest = failedUntil.min(by: { $0.value < $1.value })?.key {
                failedUntil.removeValue(forKey: oldest)
            }
            failedUntil[ObjectIdentifier(key.source)] = now + 1
            return
        }
        evict(untilAdding: bytes)
        entries[key] = Entry(image: image, bytes: bytes)
        recent.append(key)
        counts.residentBytes += bytes
        counts.builds += 1
    }

    /// GPU checks await existing work; production never calls this or waits on a miss.
    func waitForPendingWork() async {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume() }
        }
    }
}
