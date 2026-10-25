import Foundation
import Observation

/// The guide catalog is authored per release; builds without a matching catalog stay quiet.
@MainActor @Observable
final class FeatureGuideState {
    static let shared = FeatureGuideState()
    static let releaseVersion = "0.1.72"
    static let seenKey = "featureGuide.presentedVersions"

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
    var hasBeenPresented: Bool { (defaults.stringArray(forKey: Self.seenKey) ?? []).contains(version) }

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
    }

    func beginTour(in window: UUID) {
        guard isWelcome(in: window) else { return }
        phase = .tour(0)
    }

    func advance(in window: UUID) {
        guard let step = step(in: window) else { return }
        if step < 2 { phase = .tour(step + 1) } else { finish(in: window) }
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
