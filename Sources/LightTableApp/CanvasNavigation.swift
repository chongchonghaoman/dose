import AppKit
import SwiftUI

/// Observe only scrolls over the table. The tray and toolbar retain native input.
struct CanvasNavigation: NSViewRepresentable {
    let enabled: Bool
    let moved: (CGSize) -> Void
    let zoomed: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollView { ScrollView() }
    func updateNSView(_ view: ScrollView, context: Context) {
        view.enabled = enabled; view.moved = moved; view.zoomed = zoomed
    }
    static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }

    final class ScrollView: NSView {
        var enabled = true
        var moved: ((CGSize) -> Void)?
        var zoomed: ((Double, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.enabled, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), point.y >= 64 else { return event }
                let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                if event.modifierFlags.contains(.command) {
                    self.zoomed?(exp(Double(event.scrollingDeltaY * factor) * 0.006), CGPoint(x: point.x, y: point.y - 64))
                } else {
                    var dx = event.scrollingDeltaX * factor
                    var dy = event.scrollingDeltaY * factor
                    if event.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
                    self.moved?(CGSize(width: dx, height: dy))
                }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
