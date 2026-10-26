import Foundation
import Observation

enum FeatureGuideTarget: Hashable {
    case tools, magnification, removal, overview, loupe, viewingArea, trayImport, trayTabs

    static func releaseTour(step: Int, loupeEnabled: Bool) -> Self {
        switch step {
        case 0: return .trayImport
        case 1: return .viewingArea
        case 2: return .trayTabs
        default: break
        }
        guard loupeEnabled else { return .loupe }
        switch step {
        case 4: return .viewingArea
        case 5: return .magnification
        default: return .loupe
        }
    }
}

/// The guide catalog is authored per release; builds without a matching catalog stay quiet.
@MainActor @Observable
final class FeatureGuideState {
    static let shared = FeatureGuideState()
    static let releaseVersion = "0.1.73"
    static let seenKey = "featureGuide.presentedVersions"
    static let seenRevisionKey = "featureGuide.presentedRevisions"
    static let contentRevision = "trays-1"
    static let tourStepCount = 6

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
        guard isWelcome(in: window) else { return }
        var versions = defaults.stringArray(forKey: Self.seenKey) ?? []
        if !versions.contains(version) { versions.append(version) }
        defaults.set(versions, forKey: Self.seenKey)
        var revisions = defaults.stringArray(forKey: Self.seenRevisionKey) ?? []
        if !revisions.contains(presentationID) { revisions.append(presentationID) }
        defaults.set(revisions, forKey: Self.seenRevisionKey)
    }

    func beginTour(in window: UUID) {
        guard isWelcome(in: window) else { return }
        phase = .tour(0)
    }

    func advance(in window: UUID) {
        guard let step = step(in: window) else { return }
        if step + 1 < Self.tourStepCount { phase = .tour(step + 1) } else { finish(in: window) }
    }

    func previous(in window: UUID) {
        guard let step = step(in: window) else { return }
        phase = .tour(max(0, step - 1))
    }

    func dismissWelcome(in window: UUID) {
        // SwiftUI may dismiss the sheet after beginTour; preserve that next phase.
        if isWelcome(in: window) { finish(in: window) }
    }

    func finish(in window: UUID) {
        guard owner == window else { return }
        phase = .idle
        owner = nil
    }
}
