import AppKit
import SwiftUI

/// Owns input and the fullscreen transition for one slideshow presentation.
struct SlideshowWindow: NSViewRepresentable {
    let ready: Bool
    let next: () -> Void
    let previous: () -> Void
    let exit: () -> Void
    let presentationReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.coordinator = context.coordinator
        context.coordinator.update(ready: ready, next: next, previous: previous,
                                   exit: exit, presentationReady: presentationReady)
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        context.coordinator.update(ready: ready, next: next, previous: previous,
                                   exit: exit, presentationReady: presentationReady)
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: WindowView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.detach()
    }

    final class WindowView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// A transparent delegate proxy is needed for AppKit fullscreen failure
    /// callbacks, which do not have corresponding window notifications.
    final class Coordinator: NSObject, NSWindowDelegate {
        private enum Phase { case windowed, entering, fullscreen, exiting, closed }
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?
        private var monitor: Any?
        private var phase = Phase.windowed
        private var active = false
        private var ready = false
        private var ownsFullscreen = false
        private var didReportReady = false
        // AppKit holds its delegate weakly. Keep the proxy alive when the SwiftUI
        // view disappears before the enter/exit animation has finished.
        private var retainedForRestoration: Coordinator?
        private var next: (() -> Void)?
        private var previous: (() -> Void)?
        private var exit: (() -> Void)?
        private var presentationReady: (() -> Void)?

        func update(ready: Bool, next: @escaping () -> Void, previous: @escaping () -> Void,
                    exit: @escaping () -> Void, presentationReady: @escaping () -> Void) {
            self.ready = ready
            self.next = next
            self.previous = previous
            self.exit = exit
            self.presentationReady = presentationReady
            DispatchQueue.main.async { [weak self] in self?.beginPresentationIfReady() }
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            guard window !== newWindow else { return }
            // A representable normally stays in one window. Never transfer an
            // unfinished fullscreen transition into a different window.
            guard window == nil else { return }
            window = newWindow
            if let retiring = newWindow.delegate as? Coordinator, !retiring.active {
                // A rapid re-entry can replace a presentation still restoring
                // the window. Transfer that transition instead of racing it.
                phase = retiring.phase
                ownsFullscreen = retiring.ownsFullscreen
                previousDelegate = retiring.previousDelegate
                retiring.finish()
            } else {
                phase = newWindow.styleMask.contains(.fullScreen) ? .fullscreen : .windowed
                previousDelegate = newWindow.delegate
            }
            newWindow.delegate = self
            active = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.active, let window = self.window,
                      event.window === window, window.isKeyWindow,
                      NSApp.modalWindow == nil, window.attachedSheet == nil, window.sheetParent == nil,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                switch event.keyCode {
                case 53:
                    if !event.isARepeat { self.exit?() }
                    return nil
                case 123, 124, 125, 126:
                    guard self.ready, self.didReportReady, !event.isARepeat else { return nil }
                    if event.keyCode == 124 || event.keyCode == 125 { self.next?() }
                    else { self.previous?() }
                    return nil
                default:
                    return event
                }
            }
            // Do not start a native window transition during SwiftUI view setup.
            DispatchQueue.main.async { [weak self] in self?.beginPresentationIfReady() }
        }

        func detach() {
            active = false
            next = nil; previous = nil; exit = nil; presentationReady = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard ownsFullscreen, let window, phase != .closed else { finish(); return }
            retainedForRestoration = self
            switch phase {
            case .entering, .exiting:
                // didEnter/didFail will finish or initiate the restoration.
                break
            case .fullscreen:
                phase = .exiting
                window.toggleFullScreen(nil)
            case .windowed, .closed:
                finish()
            }
        }

        private func beginPresentationIfReady() {
            guard active, ready, let window else { return }
            switch phase {
            case .fullscreen:
                reportReady()
            case .windowed:
                guard !didReportReady else { return }
                ownsFullscreen = true
                phase = .entering
                window.toggleFullScreen(nil)
            case .entering, .exiting, .closed:
                break
            }
        }

        private func reportReady() {
            guard active, ready, !didReportReady else { return }
            didReportReady = true
            presentationReady?()
        }

        private func finish() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let window, window.delegate === self { window.delegate = previousDelegate }
            previousDelegate = nil
            window = nil
            ownsFullscreen = false
            retainedForRestoration = nil
        }

        func windowWillEnterFullScreen(_ notification: Notification) {
            phase = .entering
            previousDelegate?.windowWillEnterFullScreen?(notification)
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            phase = .fullscreen
            previousDelegate?.windowDidEnterFullScreen?(notification)
            if active { reportReady() }
            else if ownsFullscreen, let window {
                phase = .exiting
                window.toggleFullScreen(nil)
            } else { finish() }
        }

        func windowDidFailToEnterFullScreen(_ window: NSWindow) {
            phase = .windowed
            ownsFullscreen = false
            previousDelegate?.windowDidFailToEnterFullScreen?(window)
            // Keep the slideshow usable in the current window if macOS refuses
            // fullscreen; do not endlessly retry the refused transition.
            if active { reportReady() }
            else { finish() }
        }

        func windowWillExitFullScreen(_ notification: Notification) {
            phase = .exiting
            previousDelegate?.windowWillExitFullScreen?(notification)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            phase = .windowed
            ownsFullscreen = false
            previousDelegate?.windowDidExitFullScreen?(notification)
            if !active { finish() }
            else if ready, !didReportReady {
                DispatchQueue.main.async { [weak self] in self?.beginPresentationIfReady() }
            }
        }

        func windowDidFailToExitFullScreen(_ window: NSWindow) {
            phase = .fullscreen
            previousDelegate?.windowDidFailToExitFullScreen?(window)
            // AppKit refused restoration. Release our proxy instead of retaining
            // a dead slideshow forever or looping fullscreen requests.
            if !active { finish() }
        }

        func windowWillClose(_ notification: Notification) {
            phase = .closed
            previousDelegate?.windowWillClose?(notification)
            active = false
            finish()
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
