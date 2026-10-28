import AppKit
import Observation

/// All image inputs are immutable CGImages; only the worker queue owns its CI context.
struct LoupeRasterRequest: Equatable, @unchecked Sendable {
    let scene: LoupeSceneInput
    let diameter: CGFloat
    let displayScale: CGFloat
    var magnification: CGFloat? = nil
    var viewport: CGRect? = nil
    var refractionScale: CGFloat = 1

    init(scene: LoupeSceneInput, diameter: CGFloat, displayScale: CGFloat,
         magnification: CGFloat? = nil, viewport: CGRect? = nil, refractionScale: CGFloat = 1) {
        self.scene = scene; self.diameter = diameter; self.displayScale = displayScale
        self.magnification = magnification; self.viewport = viewport; self.refractionScale = refractionScale
    }

    init(_ input: LoupeDisplayInput) {
        self.init(scene: input.scene, diameter: input.diameter, displayScale: input.displayScale,
                  magnification: input.magnification, viewport: input.viewport, refractionScale: input.refractionScale)
    }

    var quick: Self {
        // A cropped animation frame already has a bounded output. Changing its
        // optical diameter here would also change the sampled source region.
        if viewport != nil { return self }
        let quickDiameter = min(diameter, LoupeGeometry.diameter)
        return Self(scene: scene, diameter: quickDiameter, displayScale: displayScale,
                    magnification: magnification.map { $0 * quickDiameter / diameter },
                    refractionScale: refractionScale)
    }
}

private final class LoupeRasterWorker: @unchecked Sendable {
    static let shared = LoupeRasterWorker()
    private let queue = DispatchQueue(label: "local.ourlighttable.loupe-raster", qos: .userInteractive)
    // Accessed exclusively by queue, including the first context/kernel creation.
    private lazy var renderer = LoupeRenderer()

    func render(_ request: LoupeRasterRequest) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                let result = autoreleasepool {
                    let scene = request.scene
                    return renderer.render(photos: scene.photos, point: scene.point, panelBounds: scene.panelBounds,
                        diameter: request.diameter, magnification: request.magnification ?? LoupeGeometry.magnification(for: request.diameter),
                        displayScale: request.displayScale, transmission: scene.transmission,
                        flare: scene.flare, brightness: scene.brightness,
                        viewport: request.viewport, refractionScale: request.refractionScale,
                        panelEDREnabled: scene.edrEnabled)
                }
                continuation.resume(returning: result)
            }
        }
    }
}

/// One request in flight and one replaceable pending request. Pointer events
/// never queue a trail of old positions or obsolete animation frames.
@MainActor @Observable final class LoupeRaster {
    typealias Render = @Sendable (LoupeRasterRequest) async -> CGImage?
    private(set) var image: CGImage?
    @ObservationIgnored private let render: Render
    @ObservationIgnored private var pending: LoupeRasterRequest?
    @ObservationIgnored private var latest: LoupeRasterRequest?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(render: @escaping Render = { await LoupeRasterWorker.shared.render($0) }) {
        self.render = render
    }

    func request(_ value: LoupeRasterRequest) {
        guard latest != value else { return }
        latest = value
        pending = value
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in await self?.drain(token: token) }
    }

    private func drain(token: Int) async {
        while !Task.isCancelled, generation == token, let value = pending {
            pending = nil
            if image == nil {
                let first = await render(value.quick)
                guard !Task.isCancelled, generation == token else { return }
                if let first { image = first }
                // Prefer a newly arrived pointer position to upgrading an old one.
                if pending != nil { continue }
                if value.quick == value { continue }
            }
            let result = await render(value)
            guard !Task.isCancelled, generation == token else { return }
            if let result { image = result }
        }
        if generation == token { task = nil }
    }

    func cancel() {
        generation += 1
        task?.cancel(); task = nil
        pending = nil; latest = nil; image = nil
    }
}
