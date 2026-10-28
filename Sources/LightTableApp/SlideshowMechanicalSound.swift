import AVFoundation
import Foundation

/// Selected recordings are bundled with the app, never read from an editor cache.
enum SlideshowSoundResource {
    static let playbackVolume: Float = 0.15
    static let changeName = "SlideChange"
    static let firstArrivalName = "ShutterArrivalRoom"

    static func url(named name: String = "ShutterClick", in bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: "wav") {
            return url
        }
        // A standalone app must not fall back to a developer's build directory.
        guard bundle.bundleURL.pathExtension != "app" else { return nil }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "wav")
        #else
        return nil
        #endif
    }
}

/// Prepare before any slide moves; a cue only restarts an already prepared player.
@MainActor
final class SlideshowMechanicalSound {
    // Ownership transfers from the preparation task to the main actor once.
    // No background code accesses the player after returning this value.
    private struct PreparedAudio: @unchecked Sendable {
        let outgoing: AVAudioPlayer?
        let firstArrival: AVAudioPlayer?
    }

    private struct AudioData: Sendable {
        let outgoing: Data?
        let firstArrival: Data?
    }

    private static let cachedData = Task.detached(priority: .userInitiated) {
        func load(_ name: String) -> Data? {
            guard let url = SlideshowSoundResource.url(named: name) else { return nil }
            return try? Data(contentsOf: url)
        }
        return AudioData(outgoing: load(SlideshowSoundResource.changeName),
                         firstArrival: load(SlideshowSoundResource.firstArrivalName))
    }
    private var preparation: Task<Void, Never>?
    private var outgoingPlayer: AVAudioPlayer?
    private var firstArrivalPlayer: AVAudioPlayer?

    func prepare() async {
        if let preparation { await preparation.value; return }
        let data = Self.cachedData
        let preparation = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                let bytes = await data.value
                func makePlayer(_ data: Data?) -> AVAudioPlayer? {
                    guard let data, let player = try? AVAudioPlayer(data: data) else { return nil }
                    player.volume = SlideshowSoundResource.playbackVolume
                    player.numberOfLoops = 0
                    guard player.prepareToPlay() else { return nil }
                    return player
                }
                return PreparedAudio(outgoing: makePlayer(bytes.outgoing),
                                     firstArrival: makePlayer(bytes.firstArrival))
            }.value
            guard !Task.isCancelled, let self else { return }
            self.outgoingPlayer = prepared.outgoing
            self.firstArrivalPlayer = prepared.firstArrival
            // Never replay an old cue after preparation completes.
        }
        self.preparation = preparation
        await preparation.value
    }

    func outgoing() { play(outgoingPlayer) }
    func firstArrival() { play(firstArrivalPlayer) }

    private func play(_ player: AVAudioPlayer?) {
        stop()
        guard let player else { return }
        _ = player.play()
    }

    func stop() {
        // Pause retains prepared buffers for the next departure.
        for player in [outgoingPlayer, firstArrivalPlayer].compactMap({ $0 }) {
            player.pause()
            player.currentTime = 0
            player.setVolume(SlideshowSoundResource.playbackVolume, fadeDuration: 0)
        }
    }

    deinit {
        preparation?.cancel()
        outgoingPlayer?.stop()
        firstArrivalPlayer?.stop()
    }
}
