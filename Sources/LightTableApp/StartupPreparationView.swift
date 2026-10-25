import AppKit
import SwiftUI
import LightTableCore

/// The update guide's card with staged presentation; actual readiness is unchanged.
struct StartupPreparationView: View {
    let model: TableModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress = 0.0
    @State private var startedAt = ProcessInfo.processInfo.systemUptime

    private var needsAttention: Bool { model.startupPhase == .needsAttention }
    private var progress: Double { model.startupPhase == .ready ? 1 : displayedProgress }
    private var photoCount: Int? {
        if needsAttention || !model.startupFailedURLs.isEmpty { return model.startupCompleted }
        return StartupPresentationProgress.photoCount(total: model.startupTotal, progress: progress)
    }
    private var stageTitle: String {
        if needsAttention { return "部分照片需要重新读取" }
        if !model.startupFailedURLs.isEmpty { return "正在整理可用照片" }
        if progress >= StartupPresentationProgress.photoStart { return "准备高清照片" }
        if progress >= 0.34 { return "准备灯箱" }
        if progress >= 0.17 { return "恢复照片摆放" }
        return "唤醒观片台"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(needsAttention ? "有几张胶片需要检查" : "正在准备观片台")
                        .font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text("恢复上次的台面，让每次凑近都清晰。")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.40))
                }
            }.padding(.bottom, 28)

            HStack {
                Text(stageTitle)
                Spacer()
                if let photoCount {
                    Text("\(photoCount) / \(model.startupTotal) 张").monospacedDigit()
                }
            }.font(.system(size: 12)).padding(.bottom, 10)
            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear).tint(Color(white: 0.16))
                .animation(reduceMotion ? nil : .linear(duration: 0.05), value: progress)
                .accessibilityLabel("观片台准备进度")
                .accessibilityValue(photoCount.map { "\(stageTitle)，\($0)张，共\(model.startupTotal)张" } ?? stageTitle)

            if needsAttention {
                Text("\(model.startupFailedURLs.count) 张照片未能读取，请确认文件或外接硬盘仍可访问。")
                    .font(.system(size: 13)).foregroundStyle(Color(white: 0.40))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(4).padding(.top, 20)
                Text(model.startupFailedURLs.prefix(3).map(\.lastPathComponent).joined(separator: "、"))
                    .font(.system(size: 11)).foregroundStyle(Color(white: 0.40))
                    .lineLimit(2).truncationMode(.middle).padding(.top, 8)
                HStack(spacing: 10) {
                    Spacer()
                    Button("先查看可用照片") { model.continueStartup() }
                        .buttonStyle(FeatureGuideButtonStyle())
                    Button("重新读取") { Task { await model.retryStartup() } }
                        .buttonStyle(FeatureGuideButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }.padding(.top, 26)
            }
        }
        .padding(32).frame(width: 520)
        .foregroundStyle(Color(white: 0.15))
        .background(Color(white: 0.98), in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.93))
        .contentShape(Rectangle())
        .onDrop(of: ["public.file-url"], isTargeted: nil) { _ in false }
        .accessibilityElement(children: .contain).accessibilityLabel("准备观片台")
        .onChange(of: model.startupAttempt) { _, _ in
            displayedProgress = 0
            startedAt = ProcessInfo.processInfo.systemUptime
        }
        .task(id: model.startupPhase) {
            // This task updates only the small loading card, never the table or
            // image pipeline. SwiftUI cancels it when this overlay disappears.
            while !Task.isCancelled {
                guard model.startupPhase == .preparing || model.startupPhase == .finishing else { return }
                let target = StartupPresentationProgress.preparation(
                    completed: model.startupCompleted, total: model.startupTotal,
                    elapsed: ProcessInfo.processInfo.systemUptime - startedAt)
                let next = reduceMotion ? target : min(target, displayedProgress + max(0.004, (target - displayedProgress) * 0.22))
                displayedProgress = max(displayedProgress, next)
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }
}
