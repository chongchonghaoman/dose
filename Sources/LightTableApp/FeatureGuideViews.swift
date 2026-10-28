import AppKit
import SwiftUI

struct FeatureGuideCommand {
    let show: () -> Void
}
private struct FeatureGuideCommandKey: FocusedValueKey {
    typealias Value = FeatureGuideCommand
}
extension FocusedValues {
    var featureGuide: FeatureGuideCommand? {
        get { self[FeatureGuideCommandKey.self] }
        set { self[FeatureGuideCommandKey.self] = newValue }
    }
}
struct FeatureGuideCommands: Commands {
    @FocusedValue(\.featureGuide) private var guide
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("本次更新…") { guide?.show() }
                .disabled(guide == nil)
        }
    }
}

struct FeatureGuideWelcome: View {
    let version: String
    var required = false
    let close: () -> Void
    let tour: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("观片台已更新").font(.system(size: 21, weight: .semibold))
                    Text("v\(version) · 诊断采样")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 24)
            feature("waveform.path.ecg", title: "诊断采样",
                    text: "遇到卡顿或显示异常时，在「观片台」菜单选「开始诊断采样…」，复现问题后选「停止并上传诊断…」。",
                    note: "上传前列出数据类别并需确认，不含照片、路径或电脑名。上传后一定要把诊断编号发给维护者。")
            HStack(spacing: 10) {
                Spacer()
                if !required { Button("开始观片", action: close).buttonStyle(FeatureGuideButtonStyle()) }
                Button("看看怎么用", action: tour).buttonStyle(FeatureGuideButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }.padding(.top, 30)
            Text("以后可在「帮助 → 本次更新」重看")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 18)
        }
        .padding(32).frame(width: 520)
        .foregroundStyle(Color(white: 0.15))
        .background(Color(white: 0.98))
        .overlay(alignment: .topTrailing) {
            if !required {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("关闭更新说明").padding(10)
            }
        }
        .onExitCommand { if !required { close() } }
        .interactiveDismissDisabled(required)
    }

    private func feature(_ icon: String, title: String, text: String, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 25, weight: .light))
                .frame(width: 34).padding(.top, 2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                if let note { Text(note).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
}

struct FeatureGuideButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 17).frame(height: 36)
            .foregroundStyle(primary ? Color.white : Color(white: 0.16))
            .background(primary ? Color(white: configuration.isPressed ? 0.29 : 0.16)
                        : Color(white: configuration.isPressed ? 0.86 : 0.92), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct FeatureGuideAnchors: PreferenceKey {
    static var defaultValue: [FeatureGuideTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [FeatureGuideTarget: Anchor<CGRect>], nextValue: () -> [FeatureGuideTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
extension View {
    func featureGuideTarget(_ target: FeatureGuideTarget) -> some View {
        anchorPreference(key: FeatureGuideAnchors.self, value: .bounds) { [target: $0] }
    }
}
struct FeatureGuideBounds: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct FeatureGuideTour: View {
    let step: Int
    let anchors: [FeatureGuideTarget: Anchor<CGRect>]
    let boardFrame: CGRect
    let hasPhotos: Bool
    let selectedCount: Int
    let loupeEnabled: Bool
    var required = false
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @State private var cardHeight: CGFloat = 230

    private var target: FeatureGuideTarget {
        FeatureGuideTarget.releaseTour(step: step, loupeEnabled: loupeEnabled)
    }
    private var title: String {
        ["打开「观片台」菜单", "照常操作，复现问题", "停止并上传，发送编号"][step]
    }
    private var details: String {
        switch step {
        case 0: return "遇到卡顿、放大镜异常或显示问题时，\n点屏幕左上角菜单栏的「观片台」，\n选择「开始诊断采样…」。"
        case 1: return "像平常一样拖片、开关放大镜或 EDR，\n让问题再出现一次。采样最长 15 分钟，\n只记录状态和每秒帧耗时，不含照片。"
        default: return "回到「观片台」菜单，\n选择「停止并上传诊断…」，\n确认要发送的内容后上传。"
        }
    }
    private var context: String? {
        if step == 1 && !hasPhotos { return "台面还没有照片，可先导入几张再复现。" }
        if step == 2 { return "网络失败时记录保留在本机，可从菜单重试；取消上传会删除记录。" }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = anchors[target].map { proxy[$0] }
            let width = min(310.0, max(240, proxy.size.width - 32))
            let proposedX = target == .menuBar ? width / 2 + 8 : (rect?.maxX ?? proxy.size.width - 24) - width / 2
            let isTrayTarget = target == .trayImport || target == .trayTabs
            let anchorY = target == .viewingArea ? (rect?.minY ?? 0) + 64 : (rect?.maxY ?? 52)
            let proposedY = isTrayTarget
                ? (rect?.minY ?? boardFrame.maxY) - cardHeight / 2 - 14
                : anchorY + cardHeight / 2 + 14
            let x = target == .menuBar ? proposedX : min(proxy.size.width - width / 2 - 16, max(width / 2 + 16, proposedX))
            let y = target == .menuBar ? cardHeight / 2 + 8
                : min(proxy.size.height - cardHeight / 2 - 16, max(cardHeight / 2 + 16, proposedY))
            if let rect {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .frame(width: rect.width + 8, height: rect.height + 8)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 12) {
                if target == .menuBar {
                    Label("屏幕左上角菜单栏「观片台」", systemImage: "arrow.up.left")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                HStack {
                    Text("\(step + 1) / \(FeatureGuideState.tourStepCount)").monospacedDigit()
                    Spacer()
                    if !required { Button("跳过", action: close).buttonStyle(.plain).accessibilityLabel("跳过新功能指引") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(details).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                if step == 2 {
                    Label("上传后，一定要把显示的诊断编号发给维护者！没有编号就找不到你的记录。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let context { Text(context).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2) }
                HStack {
                    Button("上一步", action: previous).buttonStyle(.plain).font(.system(size: 12))
                        .disabled(step == 0).opacity(step == 0 ? 0 : 1)
                    Spacer()
                    Button(step + 1 == FeatureGuideState.tourStepCount ? "开始观片" : "下一步", action: next)
                        .buttonStyle(FeatureGuideButtonStyle(primary: true))
                }.padding(.top, 4)
            }
            .padding(21).frame(width: width, alignment: .leading)
            .foregroundStyle(Color(white: 0.15))
            .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .background(GeometryReader { card in
                Color.clear.preference(key: FeatureGuideBounds.self, value: card.frame(in: .named("featureGuideOverlay")))
                    .onChange(of: card.size.height, initial: true) { _, height in cardHeight = height }
            })
            .position(x: x, y: y)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("新功能操作提示，第\(step + 1)步，共\(FeatureGuideState.tourStepCount)步")
        }
    }
}

/// Observe only this window's lifecycle. No timer and no global key monitor.
struct FeatureGuideWindow: NSViewRepresentable {
    let onKey: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onKey = onKey }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }
    final class ObserverView: NSView {
        var onKey: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didEndSheetNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.report() })
            }
            report()
        }
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onKey?(self.window?.isKeyWindow == true && self.window?.attachedSheet == nil)
            }
        }
        func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = [] }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
