import AppKit
import SwiftUI

/// Intercept only a Shift-drag that starts on the board. This keeps the
/// existing photo drags, empty-board panning, toolbar and tray independent.
struct CanvasSelection: NSViewRepresentable {
    let enabled: Bool
    var excludedRect: CGRect? = nil
    let began: () -> Void
    let changed: (CGRect) -> Void
    let ended: () -> Void
    let cancelled: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.began = began; view.changed = changed
        view.ended = ended; view.cancelled = cancelled
        view.excludedRect = excludedRect
        view.enabled = enabled
        if !enabled { view.cancel() }
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var excludedRect: CGRect?
        var enabled = false
        var began: (() -> Void)?
        var changed: ((CGRect) -> Void)?
        var ended: (() -> Void)?
        var cancelled: (() -> Void)?
        private var origin: CGPoint?
        private var swallowRelease = false
        private var hasCursor = false
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handle(event)
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    self?.cancel(); self?.swallowRelease = false
                }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            if event.type == .keyDown {
                guard origin != nil, event.keyCode == 53 else { return event }
                cancel(); return nil
            }
            if event.type == .leftMouseDown {
                swallowRelease = false
                let point = convert(event.locationInWindow, from: nil)
                guard enabled, window?.isKeyWindow == true, window?.attachedSheet == nil,
                      event.modifierFlags.contains(.shift),
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      bounds.contains(point), point.y >= 64,
                      excludedRect?.contains(point) != true else { return event }
                origin = point
                NSCursor.crosshair.push(); hasCursor = true
                began?()
                return nil
            }
            guard let origin else {
                if swallowRelease {
                    if event.type == .leftMouseUp { swallowRelease = false }
                    return nil
                }
                return event
            }
            let raw = convert(event.locationInWindow, from: nil)
            let point = CGPoint(x: min(bounds.maxX, max(bounds.minX, raw.x)),
                                y: min(bounds.maxY, max(64, raw.y)))
            changed?(CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                            width: abs(point.x - origin.x), height: abs(point.y - origin.y)))
            if event.type == .leftMouseUp {
                self.origin = nil; releaseCursor(); ended?()
            }
            return nil
        }

        func cancel() {
            guard origin != nil else { return }
            origin = nil; swallowRelease = true; releaseCursor(); cancelled?()
        }
        private func releaseCursor() {
            if hasCursor { NSCursor.pop(); hasCursor = false }
        }
        func stop() {
            cancel(); swallowRelease = false
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        }
        deinit {
            if hasCursor { NSCursor.pop() }
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }
}
