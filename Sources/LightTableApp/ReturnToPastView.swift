import AppKit
import SwiftUI
import WebKit

struct ReturnToPastPlayer: View {
    @Bindable var session: ReturnToPastSession
    var interactive = true
    var focus: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if session.canPlay, let scene = session.scene, let directory = session.directory {
                    ReturnToPastBrowser(scene: scene, directory: directory, runID: session.runID,
                        interactive: interactive, reduceMotion: reduceMotion,
                        skipReveal: session.hasRevealed, resetID: session.resetID,
                        focus: focus, revealed: { session.revealed(run: $0) },
                        failed: { session.viewerFailed($0, run: $1) })
                        .id(session.runID)
                } else {
                    VStack(spacing: 10) {
                        if session.phase == .failed {
                            Image(systemName: "exclamationmark.circle").font(.system(size: 20, weight: .light))
                            Text(session.status).font(.system(size: 11)).lineLimit(4)
                                .multilineTextAlignment(.center).help(session.status)
                            Button("重试") { session.retry() }.buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 6)
                                .background(.white.opacity(0.15), in: Capsule())
                        } else {
                            ReturnToPastGenerationProgress(status: session.status, fraction: session.progress)
                                .id(session.runID)
                        }
                    }
                    .foregroundStyle(.white.opacity(0.82)).padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipped()
        }
        .background(.black)
        .accessibilityLabel("回到过去")
        .accessibilityHint("左键拖动小幅旋转，右键拖动小幅平移，滚轮或捏合自由缩放，双击复位。Esc返回观片台。")
    }

}

private struct ReturnToPastGenerationProgress: View {
    let status: String
    let fraction: Double?
    @State private var started = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: started, by: fraction == nil && !reduceMotion ? 1.0 / 30 : 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(started))
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        if let fraction {
                            Capsule().fill(.white.opacity(0.85))
                                .frame(width: proxy.size.width * min(1, max(0, fraction)))
                        } else {
                            let position = reduceMotion ? 0.5 : (sin(elapsed * 2.4 - .pi / 2) + 1) / 2
                            Capsule().fill(.white.opacity(0.75))
                                .frame(width: proxy.size.width * 0.24)
                                .offset(x: proxy.size.width * 0.76 * position)
                        }
                    }
                }.frame(width: 240, height: 5).accessibilityHidden(true)
                Text(status).font(.system(size: 11)).lineLimit(4)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                HStack(spacing: 12) {
                    if let fraction { Text("\(Int(min(1, max(0, fraction)) * 100))%") }
                    Text("已用时 \(Int(elapsed)) 秒")
                }
                .font(.system(size: 10, design: .monospaced)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Only these four files are reachable from WebKit. Source photographs, Python
/// and the user's filesystem are never exposed through the custom scheme.
private final class ReturnToPastScheme: NSObject, WKURLSchemeHandler {
    private let files: [String: (URL, String)]
    // WebKit starts and stops tasks on the main thread. Deliver there too so a
    // cancellation cannot interleave with a response or wait on a worker lock.
    private var active = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "app.ourlighttable.return-to-past.resources", qos: .userInitiated)

    init(directory: URL) {
        let resources = ReturnToPastResources.directory
        files = [
            "/viewer.html": (resources.appendingPathComponent("viewer.html"), "text/html"),
            "/viewer.js": (resources.appendingPathComponent("viewer.js"), "text/javascript"),
            "/viewer-playcanvas.js": (resources.appendingPathComponent("viewer-playcanvas.js"), "text/javascript"),
            "/scene.ply": (directory.appendingPathComponent("scene.ply"), "application/octet-stream")
        ]
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let requestURL = urlSchemeTask.request.url
        active.insert(id)
        queue.async { [self] in
            let result: Result<(URLResponse, Data), Error> = Result {
                guard let url = requestURL,
                      url.scheme == "lighttable-scene", url.host == "local",
                      let (file, mime) = files[url.path] else { throw URLError(.fileDoesNotExist) }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                return (URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                    textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil), data)
            }
            DispatchQueue.main.async { [self] in
                guard active.remove(id) != nil else { return }
                switch result {
                case .success(let (response, data)):
                    urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
                case .failure(let error): urlSchemeTask.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }
}

private struct ReturnToPastBrowser: NSViewRepresentable {
    let scene: ReturnToPastScene
    let directory: URL
    let runID: UUID
    let interactive: Bool
    let reduceMotion: Bool
    let skipReveal: Bool
    let resetID: Int
    let focus: () -> Void
    let revealed: (UUID) -> Void
    let failed: (String, UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SceneWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ReturnToPastScheme(directory: directory), forURLScheme: "lighttable-scene")
        configuration.userContentController.add(context.coordinator, name: "returnToPast")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = SceneWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .black
        view.navigationDelegate = context.coordinator
        view.focusScene = focus
        view.interactive = interactive
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: "lighttable-scene://local/viewer.html")!))
        return view
    }

    func updateNSView(_ view: SceneWebView, context: Context) {
        let coordinator = context.coordinator
        let resetChanged = coordinator.parent.resetID != resetID
        coordinator.parent = self
        view.focusScene = focus; view.interactive = interactive
        if coordinator.ready {
            view.evaluateJavaScript("window.setInteractive(\(interactive ? "true" : "false"));")
            if resetChanged { view.evaluateJavaScript("window.resetView();") }
        }
    }

    static func dismantleNSView(_ view: SceneWebView, coordinator: Coordinator) {
        coordinator.active = false
        view.focusScene = nil
        view.stopInput()
        view.evaluateJavaScript("window.dispose && window.dispose();")
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "returnToPast")
        view.navigationDelegate = nil
    }

    final class SceneWebView: WKWebView {
        var focusScene: (() -> Void)?
        var interactive = false
        private var inputMonitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopInput()
            guard window != nil else { return }
            // WKContentView receives the native events inside WKWebView; a
            // window-local monitor keeps selection and magnify reliable there.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .magnify]) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      let root = self.window?.contentView else { return event }
                // hitTest expects the root's superview coordinates. Converting
                // through that view also handles flipped SwiftUI hosting roots.
                let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                guard let hit = root.hitTest(point),
                      hit === self || hit.isDescendant(of: self) else { return event }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.focusScene?()
                    return event
                }
                if self.interactive && event.magnification.isFinite {
                    self.evaluateJavaScript("window.magnifyBy(\(Double(event.magnification)));")
                }
                return nil
            }
        }
        func stopInput() {
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            inputMonitor = nil
        }
        deinit { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ReturnToPastBrowser
        weak var webView: WKWebView?
        var ready = false
        var active = true
        init(parent: ReturnToPastBrowser) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.scheme == "lighttable-scene",
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                guard !ready else { return }
                ready = true
                let configuration: [String: Any] = ["modelURL": "lighttable-scene://local/scene.ply",
                    "width": parent.scene.width, "height": parent.scene.height,
                    "focal": parent.scene.focal, "depth": parent.scene.depth,
                    "reduceMotion": parent.reduceMotion, "skipReveal": parent.skipReveal]
                guard let data = try? JSONSerialization.data(withJSONObject: configuration),
                      let json = String(data: data, encoding: .utf8) else { return }
                webView?.evaluateJavaScript("window.setInteractive(\(parent.interactive ? "true" : "false")); window.loadScene(\(json));") { [weak self] _, error in
                    guard let self, self.active, let error else { return }
                    self.parent.failed(error.localizedDescription, self.parent.runID)
                }
            case "revealed": parent.revealed(parent.runID)
            case "error": parent.failed(body["message"] as? String ?? "场景播放失败，请重试。", parent.runID)
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.scheme == "lighttable-scene" && url?.host == "local" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if active { parent.failed(error.localizedDescription, parent.runID) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if active { parent.failed(error.localizedDescription, parent.runID) }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if active { parent.failed("播放器已中断，请重试。", parent.runID) }
        }
    }
}

/// WebKit can become first responder; capture Escape before its responder chain.
struct ReturnToPastKeyboard: NSViewRepresentable {
    let enabled: Bool
    let exit: () -> Void
    func makeNSView(context: Context) -> Monitor { Monitor() }
    func updateNSView(_ view: Monitor, context: Context) { view.enabled = enabled; view.exit = exit }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var enabled = false
        var exit: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, event.window === self.window,
                      self.window?.isKeyWindow == true, self.window?.attachedSheet == nil,
                      NSApp.modalWindow == nil, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
                if !event.isARepeat { self.exit?() }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
