import Foundation

@main struct FeatureGuideChecks {
    @MainActor static func main() {
        let suite = "LightTable.FeatureGuideChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let a = UUID(), b = UUID()
        let oldVersions = ["0.1.72", "0.1.73", "0.1.74"]
        let oldRevisions = ["0.1.72.initial", "0.1.73.trays-1", "0.1.74.deletion-1"]
        let revision = "0.1.75.\(FeatureGuideState.contentRevision)"
        defaults.set(oldVersions, forKey: FeatureGuideState.seenKey)
        defaults.set(oldRevisions, forKey: FeatureGuideState.seenRevisionKey)
        let state = FeatureGuideState(defaults: defaults, version: "0.1.75")
        expect(state.available && !state.hasBeenPresented, "matching release starts unseen")
        state.presentAutomatically(in: a, ready: false)
        expect(state.phase == .idle, "busy windows defer notes")
        state.presentAutomatically(in: a, ready: true)
        expect(state.isWelcome(in: a), "ready window claims notes")
        expect(!state.hasBeenPresented, "claim is not presentation")
        state.presentAutomatically(in: b, ready: true)
        expect(state.owner == a, "second window cannot duplicate")
        state.didPresent(in: b)
        expect(!state.hasBeenPresented, "wrong window cannot acknowledge")
        state.finish(in: a)
        state.presentAutomatically(in: b, ready: true)
        expect(state.isWelcome(in: b), "closed unseen window does not lose notes")
        state.didPresent(in: b); state.didPresent(in: b)
        expect(defaults.stringArray(forKey: FeatureGuideState.seenKey) == oldVersions + ["0.1.75"], "presentation persists once and keeps older versions")
        expect(defaults.stringArray(forKey: FeatureGuideState.seenRevisionKey) == oldRevisions + [revision], "presentation preserves older content records")
        expect(FeatureGuideState.tourStepCount == 0, "this adjustment release contains notes without an operation tour")
        state.beginTour(in: b)
        expect(state.isWelcome(in: b) && state.step(in: b) == nil, "notes-only release cannot start a tour")
        state.advance(in: b); state.previous(in: b)
        expect(state.isWelcome(in: b), "tour navigation cannot change notes-only state")
        state.dismissWelcome(in: a)
        expect(state.isWelcome(in: b), "other window cannot dismiss notes")
        state.dismissWelcome(in: b)
        expect(state.phase == .idle && state.owner == nil, "start viewing closes notes")
        let restarted = FeatureGuideState(defaults: defaults, version: "0.1.75")
        restarted.presentAutomatically(in: a, ready: true)
        expect(restarted.phase == .idle, "restart does not repeat notes")
        restarted.replay(in: a)
        expect(restarted.isWelcome(in: a), "help replays seen notes")
        restarted.replay(in: b)
        expect(restarted.owner == a, "help does not steal other window")
        restarted.dismissWelcome(in: a)
        expect(restarted.phase == .idle, "close dismisses notes")
        let previousRelease = FeatureGuideState(defaults: defaults, version: "0.1.74")
        expect(!previousRelease.available, "old version cannot display current release notes")
        let unknown = FeatureGuideState(defaults: defaults, version: "0.1.76")
        unknown.presentAutomatically(in: a, ready: true); unknown.replay(in: a)
        expect(!unknown.available && unknown.phase == .idle, "unauthored future version stays quiet")
        expect(!unknown.hasBeenPresented, "seen versions remain isolated")

        // Earlier test builds may have recorded the version without these release notes.
        defaults.set(oldVersions + ["0.1.75"], forKey: FeatureGuideState.seenKey)
        defaults.set(oldRevisions, forKey: FeatureGuideState.seenRevisionKey)
        let upgraded = FeatureGuideState(defaults: defaults, version: "0.1.75")
        expect(!upgraded.hasBeenPresented, "earlier test builds do not suppress the release notes")
        upgraded.presentAutomatically(in: a, ready: true)
        expect(upgraded.isWelcome(in: a), "existing test users receive the new notes")
        upgraded.finish(in: a)
        expect(!upgraded.hasBeenPresented, "unrendered notes are not acknowledged")
        upgraded.presentAutomatically(in: b, ready: true); upgraded.didPresent(in: b)
        expect(upgraded.hasBeenPresented, "rendered notes are acknowledged")
        expect(defaults.stringArray(forKey: FeatureGuideState.seenKey) == oldVersions + ["0.1.75"], "upgrading keeps version history without duplicates")
        expect(defaults.stringArray(forKey: FeatureGuideState.seenRevisionKey) == oldRevisions + [revision], "upgrading preserves previous content records")
        upgraded.finish(in: b)
        let upgradedRestart = FeatureGuideState(defaults: defaults, version: "0.1.75")
        upgradedRestart.presentAutomatically(in: a, ready: true)
        expect(upgradedRestart.phase == .idle, "notes do not repeat after restart")
        print("Feature guide: \(count) checks passed")
    }
}
