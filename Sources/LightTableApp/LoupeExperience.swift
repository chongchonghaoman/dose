import AppKit
import SwiftUI
import LightTableCore

enum LoupeCloseMagnification: CaseIterable {
    case original, eight

    var title: String { self == .original ? "原倍率" : "8×" }

    func magnification(in size: CGSize) -> CGFloat {
        self == .eight ? 8 : LoupeGeometry.magnification(for: LoupeGeometry.closeDiameter(in: size))
    }
}

enum LoupeGeometry {
    static let diameter: CGFloat = 260
    static let magnification: CGFloat = 1.5
    static let enterDuration = 0.50
    static let exitDuration = 0.34
    static let focalChangeDuration = 0.26

    static func ease(_ progress: CGFloat) -> CGFloat {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func closeDiameter(in size: CGSize) -> CGFloat {
        max(diameter, min(size.width, size.height) * 0.94)
    }

    static func rasterDiameter(in size: CGSize, closeViewing: Bool) -> CGFloat {
        closeViewing ? closeDiameter(in: size) : diameter
    }

    /// Minimum translation to show the whole optic, retaining its source point.
    static func closeCenter(from origin: CGPoint, in size: CGSize) -> CGPoint {
        let radius = closeDiameter(in: size) / 2
        let inset = radius + max(8, radius * 0.025)
        func axis(_ value: CGFloat, _ length: CGFloat) -> CGFloat {
            guard length > inset * 2 else { return length / 2 }
            return min(length - inset, max(inset, value))
        }
        return CGPoint(x: axis(origin.x, size.width), y: axis(origin.y, size.height))
    }

    static func magnification(for diameter: CGFloat) -> CGFloat {
        magnification * diameter / Self.diameter
    }

    static func sourceViewport(point: CGPoint, in size: CGSize, closeViewing: Bool,
                               mode: LoupeCloseMagnification) -> CGRect {
        let ordinary = LoupeRenderer.sourceViewport(point: point, diameter: diameter, magnification: magnification)
        guard closeViewing else { return ordinary }
        let close = LoupeRenderer.sourceViewport(point: point, diameter: closeDiameter(in: size),
                                                 magnification: LoupeCloseMagnification.eight.magnification(in: size))
        // Both endpoints remain available during focal changes. The original
        // mode shares the ordinary field, even when its scale exceeds 8×.
        return ordinary.union(close)
    }
}

enum SlidePresentation {
    static func placement(_ slide: Slide, board: CGSize, aspect: CGFloat, zoom: Double,
                          movement: CGSize = .zero, magnification: CGFloat = 1,
                          rotation: Double = 0) -> SlidePlacement {
        let resting = TableCoordinates.placement(slide, boardWidth: board.width, boardHeight: board.height,
                                                 imageAspect: aspect, zoom: zoom)
        var value = slide
        value.x = (resting.x + movement.width) / board.width
        value.y = (resting.y + movement.height) / board.height
        value.width *= magnification
        value.angle += rotation
        return TableCoordinates.placement(value, boardWidth: board.width, boardHeight: board.height,
                                          imageAspect: aspect, zoom: zoom)
    }
}

struct SlidePresentationKey: PreferenceKey {
    static let defaultValue: [UUID: SlidePlacement] = [:]
    static func reduce(value: inout [UUID: SlidePlacement], nextValue: () -> [UUID: SlidePlacement]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct LoupeSceneKey: PreferenceKey {
    static let defaultValue: LoupeSceneInput? = nil
    static func reduce(value: inout LoupeSceneInput?, nextValue: () -> LoupeSceneInput?) {
        if let next = nextValue() { value = next }
    }
}

/// Transient viewing state only: never selects a film or writes a layout.
@MainActor @Observable final class LoupeExperience {
    var pointer: CGPoint? {
        didSet {
            // Use the same direct tracking before, during, and after approach.
            // A brief hover exit retains the last point until input resumes.
            if anchor != nil, let pointer { anchor = pointer }
            updateCursorVisibility()
        }
    }
    var scene: LoupeSceneInput? {
        didSet { updateCursorVisibility() }
    }
    @ObservationIgnored var sceneEdge = DiagnosticEdgeTracker(initial: false)
    @ObservationIgnored var cursorEnabled = false {
        didSet { if cursorEnabled != oldValue { updateCursorVisibility() } }
    }
    var closeMagnification: LoupeCloseMagnification = .original
    var viewingSize = CGSize.zero
    private(set) var anchor: CGPoint?
    private(set) var isClose = false
    @ObservationIgnored private(set) var cursorHidden = false
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    var sourcePoint: CGPoint? { anchor ?? pointer }

    func cycleMagnification() {
        closeMagnification = closeMagnification == .original ? .eight : .original
    }

    @discardableResult
    func press() -> Bool {
        guard scene != nil, let point = sourcePoint else { return false }
        guard !isClose else { return true }
        returnTask?.cancel()
        anchor = point
        isClose = true
        updateCursorVisibility()
        return true
    }

    func release(reduceMotion: Bool) {
        guard isClose else { return }
        isClose = false
        returnTask?.cancel()
        if reduceMotion { finishReturn(); return }
        returnTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(LoupeGeometry.exitDuration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.finishReturn()
        }
    }

    /// Clears all transient state. Returns true only if a press or return animation was
    /// actually interrupted, so repeated resets stay idempotent for diagnostics.
    @discardableResult
    func cancel() -> Bool {
        let wasActive = isClose || anchor != nil
        returnTask?.cancel()
        isClose = false
        anchor = nil
        setCursorHidden(false)
        return wasActive
    }

    private func finishReturn() {
        anchor = nil
        updateCursorVisibility()
    }

    private func updateCursorVisibility() {
        // A visible ordinary lens owns the cursor too. Leaving the canvas or
        // losing window/tool availability always releases that ownership.
        setCursorHidden(cursorEnabled && scene != nil && pointer != nil)
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }
}

/// Keep pointer tracking independent of the lens tree and cursor visibility.
struct LoupePointerTracking: NSViewRepresentable {
    let moved: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.moved = moved
        view.scheduleRefresh()
    }

    final class TrackingView: NSView {
        var moved: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var lastPoint: CGPoint?
        private var refreshScheduled = false
        private weak var trackingWindow: NSWindow?
        private var previousMouseMovedSetting: Bool?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if area == nil {
                let area = NSTrackingArea(rect: .zero,
                    options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                    owner: self, userInfo: nil)
                addTrackingArea(area)
                self.area = area
            }
            scheduleRefresh()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restoreWindowMouseMovedSetting()
            trackingWindow = window
            previousMouseMovedSetting = window?.acceptsMouseMovedEvents
            if let window { window.acceptsMouseMovedEvents = true }
            scheduleRefresh()
        }

        override func layout() {
            super.layout()
            scheduleRefresh()
        }

        override func mouseMoved(with event: NSEvent) { refreshPointer() }
        override func mouseEntered(with event: NSEvent) { refreshPointer() }
        override func mouseExited(with event: NSEvent) { refreshPointer() }

        func scheduleRefresh() {
            guard !refreshScheduled else { return }
            refreshScheduled = true
            // AppKit layout and SwiftUI updates must not synchronously publish state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refreshPointer()
            }
        }

        private func refreshPointer() {
            let point: CGPoint?
            if let window, window.isVisible, !isHiddenOrHasHiddenAncestor {
                let current = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                point = visibleRect.contains(current) ? current : nil
            } else {
                point = nil
            }
            // An exit queued before a lens/cursor update can arrive while the
            // pointer is still inside. Never tear down the lens for that event.
            guard point != lastPoint else { return }
            lastPoint = point
            moved?(point)
        }

        private func restoreWindowMouseMovedSetting() {
            if let trackingWindow, let previousMouseMovedSetting {
                trackingWindow.acceptsMouseMovedEvents = previousMouseMovedSetting
            }
            trackingWindow = nil
            previousMouseMovedSetting = nil
        }

        deinit { restoreWindowMouseMovedSetting() }
    }
}

struct LoupeOverlay: View {
    let experience: LoupeExperience
    let canvasFrame: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            if let scene = experience.scene {
                let origin = CGPoint(x: canvasFrame.minX + scene.point.x, y: canvasFrame.minY + scene.point.y)
                LoupeApproach(scene: scene, origin: origin, size: proxy.size,
                              magnificationBlend: experience.closeMagnification == .eight ? 1 : 0,
                              closeViewing: experience.anchor != nil, displayScale: displayScale,
                              progress: experience.isClose ? 1 : 0)
                    // LoupeDepth owns each layer's timing. A linear clock avoids
                    // applying a second easing curve to the shared approach.
                    .animation(reduceMotion ? nil : .linear(duration: experience.isClose
                        ? LoupeGeometry.enterDuration : LoupeGeometry.exitDuration), value: experience.isClose)
                    .animation(reduceMotion || experience.anchor == nil ? nil
                        : .easeInOut(duration: LoupeGeometry.focalChangeDuration), value: experience.closeMagnification)
            }
            Color.clear.onChange(of: proxy.size, initial: true) { _, size in experience.viewingSize = size }
        }
        .clipped().allowsHitTesting(false)
    }
}

/// Eye approaches the glass: film and aperture grow together with a modest
/// difference in apparent scale, settling at the original source field.
/// Both share one optical axis so edge avoidance cannot make the image chase it.
struct LoupeDepth {
    /// Apparent film scale, independent of the circular clipping aperture.
    let scale: CGFloat
    let apertureScale: CGFloat
    let surround: Double
    let travel: CGFloat
    let apertureTravel: CGFloat

    init(progress: CGFloat, finalScale: CGFloat, finalFilmScale: CGFloat? = nil) {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        let final = finalScale.isFinite ? max(1, finalScale) : 1
        // One eye-distance timeline starts both layers immediately. The film's
        // small lead describes a changing viewing distance, not a separate zoom.
        let aperture = LoupeGeometry.ease(p)
        let film = aperture + 0.22 * aperture * (1 - aperture)
        scale = 1 + ((finalFilmScale ?? final) - 1) * film
        apertureScale = 1 + (final - 1) * aperture
        surround = Double(LoupeGeometry.ease((p - 0.12) / 0.78))
        travel = aperture
        apertureTravel = aperture
    }

    /// Same center for the enlarged image and its smaller clipping aperture.
    /// No catch-up constraint or piecewise distance clamp is needed at the sides.
    func rearCenter(origin: CGPoint, target: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (target.x - origin.x) * travel,
                y: origin.y + (target.y - origin.y) * travel)
    }
}

/// The ordinary field and the original mode keep their existing layer-only
/// animation. The 8× mode samples source pixels at its actual viewing scale;
/// its drawable is never larger than the original close-view drawable.
struct LoupeSampling {
    let depth: LoupeDepth
    let diameter: CGFloat
    let magnification: CGFloat
    let contentScale: CGFloat
    let refractionScale: CGFloat

    init(in size: CGSize, closeViewing: Bool, mode: LoupeCloseMagnification, progress: CGFloat) {
        self.init(in: size, closeViewing: closeViewing,
                  magnificationBlend: mode == .eight ? 1 : 0, progress: progress)
    }

    init(in size: CGSize, closeViewing: Bool, magnificationBlend: CGFloat, progress: CGFloat) {
        let blend = magnificationBlend.isFinite ? min(1, max(0, magnificationBlend)) : 0
        let aperture = LoupeGeometry.closeDiameter(in: size) / LoupeGeometry.diameter
        let eight = 8 / LoupeGeometry.magnification
        // Equal progress changes the field by equal proportions. Keep the
        // optical centre fixed and preserve both existing endpoint render paths.
        let film = blend == 0 ? aperture : (blend == 1 ? eight : aperture * pow(eight / aperture, blend))
        depth = LoupeDepth(progress: progress, finalScale: aperture, finalFilmScale: film)
        // Retain resolution through return; mouse movement at rest stays 260pt.
        diameter = LoupeGeometry.rasterDiameter(in: size, closeViewing: closeViewing)
        let relativeScale = depth.scale / depth.apertureScale
        let originalDepth = LoupeDepth(progress: progress, finalScale: aperture)
        let originalRelativeScale = originalDepth.scale / originalDepth.apertureScale
        contentScale = blend == 0 ? originalRelativeScale : (blend == 1 ? 1 : 1 + (originalRelativeScale - 1) * (1 - blend))
        magnification = LoupeGeometry.magnification(for: diameter) * (relativeScale / contentScale)
        refractionScale = 1 - 0.25 * LoupeGeometry.ease(progress)
    }

    func input(scene: LoupeSceneInput, displayScale: CGFloat) -> LoupeDisplayInput {
        LoupeDisplayInput(scene: scene, diameter: diameter, magnification: magnification,
                         displayScale: displayScale, refractionScale: refractionScale)
    }
}

private struct LoupeSampledImage: View {
    let input: LoupeDisplayInput
    let contentScale: CGFloat
    let glass: LoupeGlassPose
    @State private var raster = LoupeRaster()

    var body: some View {
        OpticalLoupe(image: raster.image, live: OpticalMetalView.gpu == nil ? nil : input,
                     transmission: input.scene.transmission, flare: input.scene.flare, brightness: input.scene.brightness,
                     edrEnabled: input.scene.edrEnabled,
                     contentScale: contentScale, glass: glass)
            .onChange(of: input, initial: true) { _, value in
                if OpticalMetalView.gpu == nil { raster.request(LoupeRasterRequest(value)) }
            }
            .onDisappear { raster.cancel() }
    }
}

struct LoupeApproach: View, Animatable {
    let scene: LoupeSceneInput
    let origin: CGPoint
    let size: CGSize
    var magnificationBlend: CGFloat
    let closeViewing: Bool
    let displayScale: CGFloat
    var progress: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, magnificationBlend) }
        set { progress = newValue.first; magnificationBlend = newValue.second }
    }

    var body: some View {
        let target = LoupeGeometry.closeCenter(from: origin, in: size)
        let sampling = LoupeSampling(in: size, closeViewing: closeViewing, magnificationBlend: magnificationBlend, progress: progress)
        let depth = sampling.depth
        let front = CGPoint(x: origin.x + (target.x - origin.x) * depth.apertureTravel,
                            y: origin.y + (target.y - origin.y) * depth.apertureTravel)
        let glass = LoupeGlassPose(origin: origin, size: size, progress: progress, reduceMotion: reduceMotion)
        ZStack(alignment: .topLeading) {
            Color.black.opacity(depth.surround)
            // Scale only the source pixels inside the clip, then grow the clip.
            // Keep the final-resolution GPU surface throughout the approach.
            LoupeSampledImage(input: sampling.input(scene: scene, displayScale: displayScale),
                              contentScale: sampling.contentScale, glass: glass)
                .scaleEffect(depth.apertureScale).position(front)
        }
        // This Animatable view already evaluates the approach clock. Descendants
        // must not start another position/scale animation when the pointer moves.
        .transaction { $0.animation = nil }
    }
}

/// Only the glass surface responds to the observer angle. Image sampling never shifts.
struct LoupeGlassPose: Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var approach: CGFloat = 0

    init() {}
    init(origin: CGPoint, size: CGSize, progress: CGFloat, reduceMotion: Bool) {
        func axis(_ position: CGFloat, _ length: CGFloat) -> CGFloat {
            guard !reduceMotion, position.isFinite, length.isFinite, length > 0 else { return 0 }
            return tanh((position / length - 0.5) * 2)
        }
        x = axis(origin.x, size.width)
        y = axis(origin.y, size.height)
        approach = LoupeGeometry.ease(progress)
    }
    var angle: Double { Double(x * 14 + y * 8) }
    // Surface reflection softens as the eye approaches the clear glass.
    var rimIntensity: Double { 1 - Double(approach) }
    var intensity: Double { 0.45 + 0.55 * rimIntensity }
}

/// A translucent pale cross-section replaces the opaque housing around the glass.
struct LoupeGlassSurface: View {
    let pose: LoupeGlassPose
    let transmission: Double
    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            ZStack {
                Circle().fill(RadialGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.946),
                    .init(color: .black.opacity(0.075), location: 0.960),
                    .init(color: Color(red: 0.86, green: 0.93, blue: 0.91).opacity(0.24), location: 0.976),
                    .init(color: .white.opacity(0.38), location: 0.988),
                    .init(color: .white.opacity(0.55), location: 0.996),
                    .init(color: .clear, location: 1)
                ], center: .center, startRadius: 0, endRadius: radius))
                Circle().fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.44),
                    .init(color: .white.opacity(0.10), location: 0.53),
                    .init(color: .white.opacity(0.24), location: 0.64),
                    .init(color: .clear, location: 0.77),
                    .init(color: .clear, location: 0.88),
                    .init(color: .white.opacity(0.06), location: 0.96),
                    .init(color: .clear, location: 1)
                ], center: UnitPoint(x: 0.5 + pose.x * 0.04, y: 0.5 + pose.y * 0.04),
                   angle: .degrees(pose.angle)))
                .mask(Circle().fill(RadialGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.84),
                    .init(color: .white.opacity(0.035), location: 0.90),
                    .init(color: .white.opacity(0.20), location: 0.95),
                    .init(color: .white.opacity(0.55), location: 0.982),
                    .init(color: .white.opacity(0.40), location: 0.995),
                    .init(color: .clear, location: 1)
                ], center: .center, startRadius: 0, endRadius: radius)))
                Circle().inset(by: 1.5).trim(from: 0.53, to: 0.72)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(0.26), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    .rotationEffect(.degrees(pose.angle))
            }
            .opacity(pose.intensity * (0.55 + 0.45 * min(1, max(0, transmission))))
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A local monitor receives both key edges without requiring focus or a menu shortcut.
struct LoupeKeyboard: NSViewRepresentable {
    let enabled: Bool
    let pressed: () -> Bool
    let released: () -> Void
    let cancelled: () -> Void
    let cycleMagnification: () -> Void
    var loupeEnabled = true
    var toggleEDR: (() -> Void)? = nil
    var availabilityChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.availabilityChanged = availabilityChanged
        view.enabled = enabled; view.pressed = pressed
        view.released = released; view.cancelled = cancelled
        view.cycleMagnification = cycleMagnification
        view.toggleEDR = toggleEDR
        view.loupeEnabled = loupeEnabled
        if !enabled { view.reset() }
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var enabled = false {
            didSet { updateAvailability() }
        }
        var loupeEnabled = true {
            didSet {
                if !loupeEnabled { resetLoupe() }
                updateAvailability()
            }
        }
        var pressed: (() -> Bool)?
        var released: (() -> Void)?
        var cancelled: (() -> Void)?
        var cycleMagnification: (() -> Void)?
        var toggleEDR: (() -> Void)?
        var availabilityChanged: ((Bool) -> Void)?
        private var windowActive = false
        private var held = false
        private var tabHeld = false
        private var lastAvailability: Bool?
        private var edrKeyCode: UInt16?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var becomeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            windowActive = window.isKeyWindow
            updateAvailability()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handle(event)
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    self?.windowActive = false
                    self?.updateAvailability()
                    self?.reset()
                }
            becomeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    self?.windowActive = true
                    self?.updateAvailability()
                }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            if event.type == .keyUp {
                if event.keyCode == 49, held { held = false; released?(); return nil }
                if event.keyCode == 48, tabHeld { tabHeld = false; return nil }
                if event.keyCode == edrKeyCode { edrKeyCode = nil; return nil }
            }
            guard event.type == .keyDown, enabled, window?.isKeyWindow == true,
                  window?.attachedSheet == nil, NSApp.modalWindow == nil,
                  window?.firstResponder is NSTextView == false,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            if event.keyCode == edrKeyCode { return nil }
            if event.charactersIgnoringModifiers?.lowercased() == "e" {
                guard !event.isARepeat, let toggleEDR else { return event }
                edrKeyCode = event.keyCode
                toggleEDR()
                return nil
            }
            guard loupeEnabled, event.keyCode == 49 || event.keyCode == 48 else { return event }
            if event.keyCode == 48 {
                if tabHeld { return nil }
                guard !event.isARepeat, let cycleMagnification else { return event }
                tabHeld = true
                cycleMagnification()
                return nil
            }
            if held { return nil }
            guard !event.isARepeat, pressed?() == true else { return event }
            held = true
            return nil
        }

        private func resetLoupe() { held = false; tabHeld = false; cancelled?() }
        func reset() { edrKeyCode = nil; resetLoupe() }
        private func updateAvailability() {
            let available = enabled && loupeEnabled && windowActive
            guard available != lastAvailability else { return }
            lastAvailability = available
            availabilityChanged?(available)
        }
        func stop() {
            windowActive = false
            updateAvailability()
            reset()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
            if let becomeObserver { NotificationCenter.default.removeObserver(becomeObserver) }; becomeObserver = nil
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            if let becomeObserver { NotificationCenter.default.removeObserver(becomeObserver) }
        }
    }
}
