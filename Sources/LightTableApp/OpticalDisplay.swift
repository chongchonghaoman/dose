import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// Ordinary Display P3 output; redraws only when image, light or size changes.
struct OpticalDisplay: NSViewRepresentable {
    var preview: PhotoPreview? = nil
    var image: CGImage? = nil
    var loupe: LoupeDisplayInput? = nil
    var transmission: Double = 1
    var flare: Double = 0
    var brightness: Double = 1
    func makeNSView(context: Context) -> OpticalMetalView { OpticalMetalView() }
    func updateNSView(_ view: OpticalMetalView, context: Context) {
        view.set(preview: preview, image: image, transmission: transmission,
                 flare: flare, brightness: brightness, loupe: loupe)
    }
}

final class OpticalMetalView: MTKView {
    static let gpu = MTLCreateSystemDefaultDevice()
    private static let queue = gpu?.makeCommandQueue()
    private static let renderer: CIContext? = gpu.map { CIContext(mtlDevice: $0, options: [
        .workingColorSpace: PhotoOptics.blendSpace, .cacheIntermediates: false]) }
    private static let pending = NSHashTable<OpticalMetalView>.weakObjects()
    private static var scheduled = false
    private var preview: PhotoPreview?
    private var image: CGImage?
    private(set) var loupe: LoupeDisplayInput?
    private lazy var loupeRenderer = LoupeRenderer()
    private var transmission = 1.0
    private var flare = 0.0
    private var brightness = 1.0

    // Cache the finished display pixels. Animation never reads this texture
    // back into Core Image, so every light state has the same orientation.
    private(set) var cachedStableTexture: MTLTexture?
    private var cachedStableParams: CacheParams?
    private var cacheBuildInFlight = false
    private var cacheGeneration = 0

    private struct CacheParams: Equatable {
        let source: ObjectIdentifier
        let lit: ObjectIdentifier
        let dark: ObjectIdentifier
        let flare: ObjectIdentifier
        let boosted: ObjectIdentifier
        let transmitted: Bool
        let brightness: Double

        init?(preview: PhotoPreview?, brightness: Double) {
            guard let preview else { return nil }
            source = ObjectIdentifier(preview.source)
            lit = ObjectIdentifier(preview.lit)
            dark = ObjectIdentifier(preview.dark)
            flare = ObjectIdentifier(preview.flare)
            boosted = ObjectIdentifier(preview.boosted)
            transmitted = preview.transmitted
            self.brightness = brightness
        }
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
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
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func invalidateCache() {
        cacheGeneration += 1
        cachedStableTexture = nil
        cachedStableParams = nil
        cacheBuildInFlight = false
    }

    func set(preview: PhotoPreview?, image: CGImage?, transmission: Double,
             flare: Double, brightness: Double, loupe: LoupeDisplayInput? = nil) {
        let sourceChanged = self.preview?.source !== preview?.source || self.preview?.lit !== preview?.lit ||
            self.preview?.dark !== preview?.dark || self.preview?.boosted !== preview?.boosted ||
            self.preview?.flare !== preview?.flare || self.preview?.transmitted != preview?.transmitted ||
            self.image !== image || self.brightness != brightness || self.loupe != loupe
        let changed = sourceChanged || self.transmission != transmission || self.flare != flare
        if sourceChanged { invalidateCache() }

        self.preview = preview; self.image = image; self.transmission = transmission
        self.flare = flare; self.brightness = brightness; self.loupe = loupe
        let shouldAutoResize = loupe == nil
        if autoResizeDrawable != shouldAutoResize { autoResizeDrawable = shouldAutoResize }
        if let loupe, drawableSize != loupe.pixelSize {
            // Rasterize the visible viewport at its current Retina resolution.
            drawableSize = loupe.pixelSize
        }
        if changed { needsDisplay = true }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCache()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateCache()
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

    private static func drawPending() {
        scheduled = false
        let views = pending.allObjects
        pending.removeAllObjects()
        guard let buffer = queue?.makeCommandBuffer(), let renderer else { return }
        var drawables: [CAMetalDrawable] = []
        for view in views {
            guard let window = view.window, let screen = window.screen,
                  window.frame.intersects(screen.frame),
                  view.visibleRect.width > 0, view.visibleRect.height > 0 else { continue }
            if let drawable = view.encode(into: buffer, renderer: renderer) { drawables.append(drawable) }
        }
        guard !drawables.isEmpty else { return }
        // Commit GPU work first, then present after the buffer is scheduled.
        buffer.commit()
        for drawable in drawables { drawable.present() }
    }

    private func encode(into buffer: MTLCommandBuffer, renderer: CIContext) -> CAMetalDrawable? {
        guard window != nil, drawableSize.width > 0, drawableSize.height > 0,
              let drawable = (layer as? CAMetalLayer)?.nextDrawable(),
              encode(into: drawable.texture, commandBuffer: buffer, renderer: renderer) else { return nil }
        return drawable
    }

    /// Shared by the live drawable and GPU regression checks. Cache only a
    /// fully rendered stable frame; do not generate a second image on first draw.
    @discardableResult
    func encode(into texture: MTLTexture, commandBuffer buffer: MTLCommandBuffer, renderer: CIContext) -> Bool {
        let isStable = flare == 0 && transmission == 1
        let params = CacheParams(preview: preview, brightness: brightness)
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
        guard let input = composedInput(), let fitted = fitted(input, to: size) else { return false }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: buffer)
        destination.colorSpace = PhotoOptics.blendSpace
        destination.isFlipped = true
        do { _ = try renderer.startTask(toRender: fitted, to: destination) }
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
        if let loupe {
            let scene = loupe.scene
            return loupeRenderer.composite(photos: scene.photos, point: scene.point,
                panelBounds: scene.panelBounds, diameter: loupe.diameter, magnification: loupe.magnification,
                displayScale: loupe.displayScale, transmission: scene.transmission, flare: scene.flare,
                brightness: scene.brightness, viewport: loupe.viewport, refractionScale: loupe.refractionScale)
        } else if let preview {
            return PhotoOptics.composite(preview: preview, transmission: transmission,
                flare: flare, brightness: brightness)
        } else if let image {
            return CIImage(cgImage: image)
        }
        return nil
    }
}
