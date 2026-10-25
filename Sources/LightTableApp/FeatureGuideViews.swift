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
                    Text("v\(version) · 两个让观片更顺手的变化")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 24)
            feature("rectangle.dashed", title: "多张照片，一起移出台面",
                    text: "⌘ 点选多张，或 Shift 拖动框选，\n再按 Delete 一起移出。",
                    note: "底栏照片和磁盘原图都会保留。")
            Divider().padding(.vertical, 19)
            feature("viewfinder.circle", title: "凑近看，倍率切换更顺滑",
                    text: "放大镜下按住空格，再按 Tab，\n在原倍率与 8× 之间平滑推近、拉远。")
            HStack(spacing: 10) {
                Spacer()
                Button("开始观片", action: close).buttonStyle(FeatureGuideButtonStyle())
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
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11)).frame(width: 26, height: 26) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("关闭新功能指引").padding(10)
        }
        .onExitCommand(perform: close)
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

enum FeatureGuideTarget: Hashable { case tools, magnification, removal }
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
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void
    @State private var cardHeight: CGFloat = 230

    private var target: FeatureGuideTarget {
        step == 1 ? .removal : (step == 2 && loupeEnabled ? .magnification : .tools)
    }
    private var title: String {
        ["选中想整理的照片", "一次移出，底栏还在", "凑近后，顺滑切换倍率"][step]
    }
    private var details: String {
        switch step {
        case 0: return "普通指针下，按住 ⌘ 点击多张，\n或按住 Shift 拖动框选。\n点击空白处或按 Esc 取消选择。"
        case 1: return "按 Delete，或点击「移出台面」。\n只整理台面，底栏照片和原图都保留。"
        default: return "选择放大镜，按住空格凑近，\n再按 Tab 切换原倍率／8×。\n也可以点击或拖动右侧的倍率滑块。"
        }
    }
    private var context: String? {
        if !hasPhotos { return "台面还没有照片，可从底栏拖入后再试。" }
        if step < 2 && loupeEnabled { return "先点击上方的普通指针。" }
        if step == 1 && selectedCount < 2 { return "选中多项后，台面左下角会显示移出按钮。" }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = anchors[target].map { proxy[$0] }
            let width = min(310.0, max(240, proxy.size.width - 32))
            let bottom = boardFrame.isEmpty ? proxy.size.height - 140 : boardFrame.maxY
            let proposedX = step == 1 ? (rect?.minX ?? 16) + width / 2 : (rect?.maxX ?? proxy.size.width - 24) - width / 2
            let proposedY = step == 1 ? (rect?.minY ?? bottom - 16) - cardHeight / 2 - 12 : (rect?.maxY ?? 52) + cardHeight / 2 + 14
            let x = min(proxy.size.width - width / 2 - 16, max(width / 2 + 16, proposedX))
            let y = min(proxy.size.height - cardHeight / 2 - 16, max(cardHeight / 2 + 16, proposedY))
            if let rect {
                RoundedRectangle(cornerRadius: 20).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2)
                    .frame(width: rect.width + 8, height: rect.height + 8)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(step + 1) / 3").monospacedDigit()
                    Spacer()
                    Button("跳过", action: close).buttonStyle(.plain).accessibilityLabel("跳过新功能指引")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(details).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                if let context { Text(context).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2) }
                HStack {
                    Button("上一步", action: previous).buttonStyle(.plain).font(.system(size: 12))
                        .disabled(step == 0).opacity(step == 0 ? 0 : 1)
                    Spacer()
                    Button(step == 2 ? "开始观片" : "下一步", action: next)
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
            .accessibilityElement(children: .contain).accessibilityLabel("新功能操作提示，第\(step + 1)步，共3步")
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
