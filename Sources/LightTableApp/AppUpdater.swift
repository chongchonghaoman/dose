#if canImport(Sparkle)
import AppKit
import Combine
import Sparkle

/// Sparkle owns networking, version comparison, download verification and installation.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticChecks = false
    @Published private(set) var isAvailable = false

    private let configuration: UpdateConfiguration
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var startError: String?
    private var beforeRelaunch: (() -> Void)?

    override init() {
        configuration = .read(Bundle.main.infoDictionary ?? [:],
                              isApplication: Bundle.main.bundleURL.pathExtension == "app")
        super.init()
    }

    func start(beforeRelaunch: @escaping () -> Void) {
        guard !started else { return }
        started = true
        self.beforeRelaunch = beforeRelaunch
        guard configuration == .ready else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                      updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticChecks = $0 }
            .store(in: &subscriptions)
        do {
            try updater.start()
            isAvailable = true
            // Run once per process, before Sparkle's first scheduled runloop cycle.
            // Keep respecting the user's automatic-check preference.
            if updater.automaticallyChecksForUpdates {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            startError = error.localizedDescription
            canCheckForUpdates = true
        }
    }

    func checkForUpdates() {
        if isAvailable {
            guard canCheckForUpdates else { return }
            controller?.checkForUpdates(nil)
            return
        }

        let alert = NSAlert()
        if configuration == .development {
            alert.messageText = "这是本机开发版"
            alert.informativeText = "本机开发版保留独立更新。要使用 GitHub 自动更新，请打开公开发行版「观片台」。"
        } else {
            alert.messageText = "暂时无法检查更新"
            alert.informativeText = startError ?? "应用的更新配置不完整，请重新下载公开发行版。"
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isAvailable else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        beforeRelaunch?()
    }
}
#endif
