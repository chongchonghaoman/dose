import SwiftUI

@main
struct LightTableApp: App {
    @State private var model = TableModel()
    @StateObject private var updater = AppUpdater()
    var body: some Scene {
        WindowGroup("观片台") {
            ContentView(model: model)
                .frame(minWidth: 840, minHeight: 640)
                .preferredColorScheme(.light)
                .task { updater.start(beforeRelaunch: model.flushSave) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.flushSave() }
                .onDisappear { model.flushSave() }
                .onOpenURL { url in Task { await model.importURLs([url]) } }
        }
        .defaultSize(width: 1180, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            FeatureGuideCommands()
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Toggle("自动检查更新", isOn: Binding(get: { updater.automaticChecks },
                                                    set: updater.setAutomaticChecks))
                    .disabled(!updater.isAvailable)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("选择照片文件夹…", action: model.chooseFolder).keyboardShortcut("o")
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("添加照片…", action: model.choosePhotos).keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
            }
            CommandMenu("观片") {
                Button(model.isLit ? "关灯" : "开灯") { model.isLit.toggle() }.keyboardShortcut("l", modifiers: .command)
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("普通指针") { model.loupeEnabled = false }.keyboardShortcut("a", modifiers: [])
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("放大镜") { model.loupeEnabled = true }.keyboardShortcut("v", modifiers: [])
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("整理全局", action: model.fitToWindow).keyboardShortcut("0")
                    .disabled(model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button(model.selectedIDs.count > 1 ? "移出所选 \(model.selectedIDs.count) 项" : "移出台面", action: model.removeSelected)
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.slideshowMode || model.albumEditorPresented || model.selectedIDs.isEmpty || FeatureGuideState.shared.welcomeVisible)
            }
        }
    }
}
