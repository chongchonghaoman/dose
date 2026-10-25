/// The public edition is silent and does not distribute third-party recordings.
/// Keep cue hooks so playback timing and cancellation remain unchanged.
@MainActor
final class SlideshowMechanicalSound {
    func prepare() async {}
    func outgoing() {}
    func firstArrival() {}
    func stop() {}
}
