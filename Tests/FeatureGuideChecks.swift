import Foundation

@main struct FeatureGuideChecks {
    @MainActor static func main() {
        let suite = "LightTable.FeatureGuideChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
        let a = UUID(), b = UUID()
        defaults.set(["0.1.71"], forKey: FeatureGuideState.seenKey)
        let state = FeatureGuideState(defaults: defaults, version: "0.1.72")
        expect(state.available && !state.hasBeenPresented, "matching release starts unseen")
        state.presentAutomatically(in: a, ready: false)
        expect(state.phase == .idle, "busy/nonkey windows defer")
        state.presentAutomatically(in: a, ready: true)
        expect(state.isWelcome(in: a), "ready window claims card")
        expect(!state.hasBeenPresented, "claim is not presentation")
        state.presentAutomatically(in: b, ready: true)
        expect(state.owner == a, "second window cannot duplicate")
        state.didPresent(in: b)
        expect(!state.hasBeenPresented, "wrong window cannot acknowledge")
        state.finish(in: a)
        state.presentAutomatically(in: b, ready: true)
        expect(state.isWelcome(in: b), "closed unseen window does not lose card")
        state.didPresent(in: b); state.didPresent(in: b)
        expect(defaults.stringArray(forKey: FeatureGuideState.seenKey) == ["0.1.71", "0.1.72"], "presentation persists once and keeps older records")
        state.beginTour(in: b); state.dismissWelcome(in: b)
        expect(state.step(in: b) == 0, "sheet dismissal preserves tour")
        state.advance(in: a)
        expect(state.step(in: b) == 0, "other window cannot advance")
        state.previous(in: b)
        expect(state.step(in: b) == 0, "back stops at first step")
        state.advance(in: b)
        expect(state.step(in: b) == 1, "removal step")
        state.advance(in: b)
        expect(state.step(in: b) == 2, "zoom step")
        state.previous(in: b)
        expect(state.step(in: b) == 1, "back navigation")
        state.advance(in: b); state.advance(in: b)
        expect(state.phase == .idle && state.owner == nil, "completion releases window")
        let restarted = FeatureGuideState(defaults: defaults, version: "0.1.72")
        restarted.presentAutomatically(in: a, ready: true)
        expect(restarted.phase == .idle, "restart does not repeat")
        restarted.replay(in: a)
        expect(restarted.isWelcome(in: a), "help replays seen version")
        restarted.replay(in: b)
        expect(restarted.owner == a, "help does not steal other window")
        restarted.dismissWelcome(in: a)
        expect(restarted.phase == .idle, "close dismisses card")
        restarted.replay(in: a); restarted.beginTour(in: a); restarted.finish(in: a)
        expect(restarted.phase == .idle && restarted.hasBeenPresented, "skip does not reset seen record")
        let unknown = FeatureGuideState(defaults: defaults, version: "0.1.73")
        unknown.presentAutomatically(in: a, ready: true); unknown.replay(in: a)
        expect(!unknown.available && unknown.phase == .idle, "unauthored future version stays quiet")
        expect(!unknown.hasBeenPresented, "seen versions isolated")
        print("Feature guide: \(count) checks passed")
    }
}
