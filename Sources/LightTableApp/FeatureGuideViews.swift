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
                    Text("v\(version) · 全新背光 EDR")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max.fill").accessibilityHidden(true)
                    Text("背光 EDR").fontWeight(.semibold)
                }
                .font(.system(size: 13)).foregroundStyle(Color(red: 0.57, green: 0.32, blue: 0.09))
                Text("透光更鲜明，层次依然清晰。")
                    .font(.system(size: 23, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("亮部更通透，高光保留层次；暗部保持深度，不发灰。\n看见照片的透光感，也留住细节、色彩与对比度。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Color(red: 0.98, green: 0.94, blue: 0.86), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(red: 0.73, green: 0.51, blue: 0.20).opacity(0.16)))
            .padding(.bottom, 24)
            feature("keyboard", title: "随时切换，凑近对照",
                    text: "点击顶部「背光 EDR」，或按 E 切换。\n按住空格凑近照片时，也能按 E 对照观看。")
            Divider().padding(.vertical, 18)
            feature("slider.horizontal.3", title: "亮度自由调节",
                    text: "EDR 默认 120%，可用右侧滑块调节。\n双击恢复默认；切换模式保留各自的亮度。")
            Label("优化幻灯片音效", systemImage: "speaker.wave.2")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 18)
            HStack(spacing: 10) {
                Spacer()
                Button("开始观片", action: close).buttonStyle(FeatureGuideButtonStyle(primary: true))
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
                .accessibilityLabel("关闭更新说明").padding(10)
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
        FeatureGuideTarget.releaseTour(step: step, loupeEnabled: loupeEnabled)
    }
    private var title: String {
        ["导入照片，按底栏分类", "拿到台面，再收回原栏", "单张按 Delete，整栏用右键",
         "选择放大镜", "按住空格，凑近照片", "切换观察倍率"][step]
    }
    private var details: String {
        switch step {
        case 0: return "「从文件夹导入」会追加到当前底栏。\n点标签右侧的 ➕ 新建底栏，\n点击标签切换要整理的那一栏。"
        case 1: return "从底栏拖一张照片到台面，底栏里\n就会隐藏它。选中台面照片按 Delete，\n或右键收回，就回到原底栏、原顺序。"
        case 2: return "点选底栏照片，按 Delete 删除该张。\n右键底栏标签，选择「删除底栏」可删除整栏。\n两种操作都会移除台面对应散片，磁盘原图保留。"
        case 3: return "点击圈出的放大镜，或按 V。\n把鼠标移到照片上，观察中央细节\n与外围的镜片曲率。"
        case 4: return "在照片上按住空格，松开退回。\n凑近时继续移动鼠标查看细节，\n镜缘会保留较轻的折射与反光。"
        default: return "用右侧倍率滑块选择「原倍率／8×」，\n也可以按 Tab 切换。按住空格看变化，\n小放大镜仍保持 1.5×。"
        }
    }
    private var context: String? {
        if step == 1 && selectedCount > 1 { return "已选中 \(selectedCount) 张，按 Delete 可一起收回。" }
        if step == 1 || step >= 3 {
            if !hasPhotos { return "台面还没有照片，可从底栏拖入后再试。" }
            if step == 1 && loupeEnabled { return "按 A 切回普通指针，可点选或多选照片。" }
            if !loupeEnabled && step > 3 { return "先点击圈出的放大镜，或按 V。" }
        }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = anchors[target].map { proxy[$0] }
            let width = min(310.0, max(240, proxy.size.width - 32))
            let proposedX = (rect?.maxX ?? proxy.size.width - 24) - width / 2
            let isTrayTarget = target == .trayImport || target == .trayTabs
            let anchorY = target == .viewingArea ? (rect?.minY ?? 0) + 64 : (rect?.maxY ?? 52)
            let proposedY = isTrayTarget
                ? (rect?.minY ?? boardFrame.maxY) - cardHeight / 2 - 14
                : anchorY + cardHeight / 2 + 14
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
                    Text("\(step + 1) / \(FeatureGuideState.tourStepCount)").monospacedDigit()
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
