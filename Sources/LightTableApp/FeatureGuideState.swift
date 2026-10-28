import Foundation
import Observation

enum FeatureGuideTarget: Hashable {
    case tools, magnification, removal, overview, loupe, viewingArea, trayImport, trayTabs
    /// The app menu lives outside the window; no view anchors it, so the card sits top-left.
    case menuBar

    static func releaseTour(step: Int, loupeEnabled: Bool) -> Self {
        step == 1 ? .viewingArea : .menuBar
    }
}

/// The guide catalog is authored per release; builds without a matching catalog stay quiet.
@MainActor @Observable
final class FeatureGuideState {
    static let shared = FeatureGuideState()
    static let releaseVersion = "0.1.115"
    static let seenKey = "featureGuide.presentedVersions"
    static let seenRevisionKey = "featureGuide.presentedRevisions"
    static let contentRevision = "diagnostics-1"
    static let tourStepCount = 3
    /// Diagnostics help users get their own bugs fixed, so the first run cannot skip the tour.
    static let tourRequired = true

    enum Phase: Equatable {
        case idle
        case welcome
        case tour(Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var owner: UUID?
    let version: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.defaults = defaults
        self.version = version
    }

    var available: Bool { version == Self.releaseVersion }
    var welcomeVisible: Bool { phase == .welcome }
    private var presentationID: String { "\(version).\(Self.contentRevision)" }
    var hasBeenPresented: Bool {
        (defaults.stringArray(forKey: Self.seenRevisionKey) ?? []).contains(presentationID)
    }
    /// Help replays stay skippable once the tour has been completed.
    var mustComplete: Bool { Self.tourRequired && !hasBeenPresented }

    func isWelcome(in window: UUID) -> Bool { owner == window && phase == .welcome }
    func step(in window: UUID) -> Int? {
        guard owner == window, case .tour(let step) = phase else { return nil }
        return step
    }

    func presentAutomatically(in window: UUID, ready: Bool) {
        guard ready, available, !hasBeenPresented, phase == .idle else { return }
        owner = window
        phase = .welcome
    }

    func replay(in window: UUID) {
        guard available, owner == nil || owner == window else { return }
        owner = window
        phase = .welcome
    }

    /// Called by the actual sheet's onAppear, not by a startup timer.
    func didPresent(in window: UUID) {
        guard isWelcome(in: window), !Self.tourRequired else { return }
        acknowledge()
    }

    private func acknowledge() {
        var versions = defaults.stringArray(forKey: Self.seenKey) ?? []
        if !versions.contains(version) { versions.append(version) }
        defaults.set(versions, forKey: Self.seenKey)
        var revisions = defaults.stringArray(forKey: Self.seenRevisionKey) ?? []
        if !revisions.contains(presentationID) { revisions.append(presentationID) }
        defaults.set(revisions, forKey: Self.seenRevisionKey)
    }

    func beginTour(in window: UUID) {
        guard isWelcome(in: window), Self.tourStepCount > 0 else { return }
        phase = .tour(0)
    }

    func advance(in window: UUID) {
        guard let step = step(in: window) else { return }
        if step + 1 < Self.tourStepCount { phase = .tour(step + 1); return }
        if Self.tourRequired { acknowledge() }
        finish(in: window)
    }

    func previous(in window: UUID) {
        guard let step = step(in: window) else { return }
        phase = .tour(max(0, step - 1))
    }

    func dismissWelcome(in window: UUID) {
        // SwiftUI may dismiss the sheet after beginTour; preserve that next phase.
        if isWelcome(in: window) && !mustComplete { finish(in: window) }
    }

    func finish(in window: UUID) {
        guard owner == window else { return }
        phase = .idle
        owner = nil
    }
}
