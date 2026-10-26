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
                .task(id: model.isPreparingStartup) {
                    if !model.isPreparingStartup { updater.start(beforeRelaunch: model.flushSave) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.flushSave() }
                .onDisappear { model.flushSave() }
                .onOpenURL { url in
                    let trayID = model.activeTrayID
                    Task { await model.importURLs([url], into: trayID) }
                }
        }
        .defaultSize(width: 1180, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            FeatureGuideCommands()
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Toggle("运行期间自动检查更新", isOn: Binding(get: { updater.automaticChecks },
                                                    set: updater.setAutomaticChecks))
                    .disabled(!updater.isAvailable)
                    .help("每次启动始终检查一次；此开关控制持续运行时每 24 小时的检查。")
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("从文件夹导入…", action: model.chooseFolder).keyboardShortcut("o")
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("新建底栏") { model.newTray() }
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("添加照片…", action: model.choosePhotos).keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
            }
            CommandMenu("观片") {
                Button(model.isLit ? "关灯" : "开灯") { model.isLit.toggle() }.keyboardShortcut("l", modifiers: .command)
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("普通指针") { model.loupeEnabled = false }.keyboardShortcut("a", modifiers: [])
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("放大镜") { model.loupeEnabled = true }.keyboardShortcut("v", modifiers: [])
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button("整理全局", action: model.fitToWindow).keyboardShortcut("z", modifiers: .shift)
                    .disabled(model.isPreparingStartup || model.slideshowMode || FeatureGuideState.shared.welcomeVisible)
                Button(model.selectedTrayForDeletion != nil ? "删除底栏" : (model.selectedIDs.count > 1 ? "收回所选 \(model.selectedIDs.count) 项到底栏" : "收回底栏"), action: model.deleteSelection)
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.isPreparingStartup || model.slideshowMode || model.albumEditorPresented || !model.canDeleteSelection || FeatureGuideState.shared.welcomeVisible)
            }
        }
    }
}
