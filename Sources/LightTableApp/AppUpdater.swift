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
    private var updater: SPUUpdater?
    private var userDriver: LaunchUpdateUserDriver?
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

        let driver = LaunchUpdateUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: driver, delegate: self)
        self.userDriver = driver
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticChecks = $0 }
            .store(in: &subscriptions)
        do {
            try updater.start()
            isAvailable = true
            // Run once per process, even if periodic checks are disabled. A
            // foreground check includes previously skipped versions; the driver
            // hides its initial progress, no-update and network-error dialogs.
            driver.isCheckingAtLaunch = true
            updater.checkForUpdates()
        } catch {
            startError = error.localizedDescription
            canCheckForUpdates = true
        }
    }

    func checkForUpdates() {
        if isAvailable {
            guard canCheckForUpdates else { return }
            userDriver?.isCheckingAtLaunch = false
            updater?.checkForUpdates()
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
        updater?.automaticallyChecksForUpdates = enabled
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        beforeRelaunch?()
    }
}

/// Keep Sparkle's native download/install UI, but make launch checks quiet until
/// a newer compatible release is found. Manual checks keep their normal results.
@MainActor
final class LaunchUpdateUserDriver: SPUStandardUserDriver {
    var isCheckingAtLaunch = false

    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !isCheckingAtLaunch { super.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }

    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        isCheckingAtLaunch = false
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }

    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if isCheckingAtLaunch { acknowledgement() }
        else { super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if isCheckingAtLaunch { acknowledgement() }
        else { super.showUpdaterError(error, acknowledgement: acknowledgement) }
    }

    override func dismissUpdateInstallation() {
        super.dismissUpdateInstallation()
        isCheckingAtLaunch = false
    }
}
#endif
