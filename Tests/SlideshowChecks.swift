import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import LightTableCore

@MainActor
private final class ProjectionGate {
    private var continuations: [URL: CheckedContinuation<ProjectionPhoto?, Never>] = [:]
    private(set) var started: Set<URL> = []
    private(set) var returned: Set<URL> = []

    // Deliberately ignores cancellation, like a decoder or shared cache request
    // that has already started its underlying work.
    func load(_ url: URL) async -> ProjectionPhoto? {
        started.insert(url)
        let result = await withCheckedContinuation { continuations[url] = $0 }
        returned.insert(url)
        return result
    }

    func complete(_ photo: ProjectionPhoto) {
        continuations.removeValue(forKey: photo.url)?.resume(returning: photo)
    }
}

private final class WeakPhotoPreview {
    weak var value: PhotoPreview?
    init(_ value: PhotoPreview) { self.value = value }
}

@main
struct SlideshowChecks {
    @MainActor
    static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
            print("PASS \(message)")
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition() {
                precondition(ProcessInfo.processInfo.systemUptime < deadline, "asynchronous test gate timed out")
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        func settleCallbacks() async throws {
            for _ in 0..<10 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(10))
        }

        let a = URL(fileURLWithPath: "/in-memory/slideshow-a.png")
        let b = URL(fileURLWithPath: "/in-memory/slideshow-b.png")
        let c = URL(fileURLWithPath: "/in-memory/slideshow-c.png")
        let source = makeQuadrants(width: 1000, height: 600)
        func photo(_ url: URL) -> ProjectionPhoto {
            ProjectionPhoto(url: url, sharp: source, soft: source)
        }

        let gate = ProjectionGate()
        let racing = SlideshowPlayback(loader: { await gate.load($0) })
        racing.show(a, reduceMotion: true)
        try await waitUntil { gate.started.contains(a) }
        racing.show(b, reduceMotion: true)
        try await waitUntil { gate.started.contains(b) }
        gate.complete(photo(b))
        await racing.waitForPendingLoad()
        check(racing.requestedURL == b && racing.photo?.url == b, "fast B replaces the pending request for slow A")
        gate.complete(photo(a))
        try await waitUntil { gate.returned.contains(a) }
        try await settleCallbacks()
        check(racing.requestedURL == b && racing.photo?.url == b && !racing.failed,
              "late A cannot overwrite B even when the loader ignores cancellation")
        racing.cancel()

        let cancelGate = ProjectionGate()
        let cancelled = SlideshowPlayback(loader: { await cancelGate.load($0) })
        cancelled.show(c, reduceMotion: true)
        try await waitUntil { cancelGate.started.contains(c) }
        cancelled.cancel()
        cancelGate.complete(photo(c))
        try await waitUntil { cancelGate.returned.contains(c) }
        try await settleCallbacks()
        check(cancelled.requestedURL == nil && cancelled.photo == nil && cancelled.shutter == 0 && !cancelled.failed,
              "a cancelled presentation never publishes a late photo or failure")

        var attempts = 0
        let retrying = SlideshowPlayback(loader: { url in
            if url == a {
                attempts += 1
                return attempts == 1 ? nil : photo(url)
            }
            if url == b { return nil }
            return photo(url)
        })
        retrying.show(a, reduceMotion: true)
        await retrying.waitForPendingLoad()
        check(retrying.failed && retrying.photo == nil, "failed loads become an explicit failure state")
        retrying.show(a, reduceMotion: true)
        await retrying.waitForPendingLoad()
        check(attempts == 2 && !retrying.failed && retrying.photo?.url == a,
              "retrying the same URL starts a new load and clears failure")
        retrying.show(b, reduceMotion: true)
        await retrying.waitForPendingLoad()
        check(retrying.failed && retrying.photo == nil, "another unreadable slide reports failure")
        retrying.show(c, reduceMotion: true)
        await retrying.waitForPendingLoad()
        check(!retrying.failed && retrying.photo?.url == c, "a failed slide can be skipped for the next readable photo")
        retrying.cancel()

        var departures = 0, firstArrivals = 0, preparations = 0, stops = 0
        var cueOrder: [String] = []
        let awaitingWindow = SlideshowPlayback(loader: { photo($0) },
                                               outgoingSound: { departures += 1; cueOrder.append("out") },
                                               firstArrivalSound: { firstArrivals += 1; cueOrder.append("first") },
                                               prepareSound: { preparations += 1 },
                                               stopSound: { stops += 1 })
        awaitingWindow.show(a, reduceMotion: false)
        await awaitingWindow.waitForPendingLoad()
        check(awaitingWindow.photo?.url == a && awaitingWindow.shutter == 0 && departures == 0 && firstArrivals == 0 && preparations == 1,
              "audio preparation begins while the first decoded photo stays dark and silent")
        awaitingWindow.beginPresentation()
        check(awaitingWindow.phase == .arriving && awaitingWindow.shutter == 1 && departures == 0 && firstArrivals == 1,
              "the first slide reveals with only the latter-half shutter cue")
        awaitingWindow.beginPresentation()
        check(cueOrder == ["first"], "duplicate window readiness never repeats the first-arrival cue")
        await awaitingWindow.waitForPendingLoad()
        check(awaitingWindow.shutter == 1 && awaitingWindow.focus == 1 && awaitingWindow.transport == 0,
              "the first slide opens, moves to the centre and settles focus")
        let began = ProcessInfo.processInfo.systemUptime
        awaitingWindow.show(b, reduceMotion: false)
        let stopsAtRequest = stops
        try await waitUntil { awaitingWindow.phase == .departing }
        check(awaitingWindow.shutter == 1 && awaitingWindow.photo?.url == a && awaitingWindow.transport == 1 &&
              departures == 1 && cueOrder == ["first", "out"],
              "one shutter cue starts with the visible old slide moving out, before black")
        try await waitUntil { awaitingWindow.phase == .black }
        check(awaitingWindow.shutter == 0 && awaitingWindow.photo?.url == a && departures == 1 && stops == stopsAtRequest,
              "closing the shutter after departure does not cut off the recording")
        try await Task.sleep(for: .milliseconds(80))
        check(awaitingWindow.photo?.url == a && awaitingWindow.shutter == 0 && cueOrder == ["first", "out"] && stops == stopsAtRequest,
              "the black interval hides the photo and spill while allowing the shutter recording to finish")
        try await waitUntil { awaitingWindow.phase == .arriving }
        check(ProcessInfo.processInfo.systemUptime - began >= 0.20 && awaitingWindow.photo?.url == b &&
              departures == 1 && cueOrder == ["first", "out"] && stops == stopsAtRequest,
              "an 80ms departure and full 120ms black interval precede arrival without replaying or stopping audio")
        await awaitingWindow.waitForPendingLoad()
        check(awaitingWindow.phase == .settled && awaitingWindow.shutter == 1 &&
              awaitingWindow.focus == 1 && awaitingWindow.transport == 0 && cueOrder == ["first", "out"] && stops == stopsAtRequest,
              "a completed slide change restores the projection without any additional audio cue")
        let stopsBeforeCancel = stops
        awaitingWindow.cancel()
        check(stops == stopsBeforeCancel + 1, "leaving the slideshow stops its mechanical sound")
        awaitingWindow.show(c, reduceMotion: true)
        await awaitingWindow.waitForPendingLoad()
        check(firstArrivals == 1, "reentering stays silent until the presentation is ready")
        awaitingWindow.beginPresentation()
        check(firstArrivals == 2 && departures == 1,
              "a new presentation receives exactly one new latter-half entry cue")
        awaitingWindow.cancel()

        let cancelledArrival = SlideshowPlayback(loader: { photo($0) })
        cancelledArrival.show(a, reduceMotion: false)
        await cancelledArrival.waitForPendingLoad()
        cancelledArrival.beginPresentation()
        cancelledArrival.cancel()
        try await Task.sleep(for: .milliseconds(300))
        check(cancelledArrival.photo == nil && cancelledArrival.shutter == 0 && cancelledArrival.transport == -1,
              "cancelling during arrival prevents any late photo or phase restoration")

        var fastDepartures = 0, fastFirstArrivals = 0, fastStops = 0
        let interrupted = SlideshowPlayback(loader: { photo($0) },
                                            outgoingSound: { fastDepartures += 1 },
                                            firstArrivalSound: { fastFirstArrivals += 1 },
                                            stopSound: { fastStops += 1 })
        interrupted.beginPresentation()
        interrupted.show(a, reduceMotion: false)
        await interrupted.waitForPendingLoad()
        interrupted.show(b, reduceMotion: false)
        try await waitUntil { interrupted.phase == .departing }
        interrupted.show(c, reduceMotion: false)
        check(interrupted.phase == .black && interrupted.shutter == 0 && fastStops == 3,
              "interrupting departure stops the old recording and hides the moving photo")
        await interrupted.waitForPendingLoad()
        check(interrupted.photo?.url == c && interrupted.phase == .settled && fastDepartures == 1 && fastStops == 3,
              "an interrupted departure never replays a stale or repeated shutter cue")
        interrupted.show(b, reduceMotion: false)
        try await waitUntil { interrupted.phase == .black }
        interrupted.show(a, reduceMotion: false)
        await interrupted.waitForPendingLoad()
        check(interrupted.photo?.url == a && fastDepartures == 2 && fastStops == 5,
              "replacing a request during black reveals only its latest target without another departure")
        interrupted.show(b, reduceMotion: false)
        try await waitUntil { interrupted.phase == .arriving }
        interrupted.show(c, reduceMotion: false)
        check(interrupted.shutter == 0, "interrupting an arrival immediately hides the moving obsolete photo")
        await interrupted.waitForPendingLoad()
        check(interrupted.photo?.url == c && interrupted.phase == .settled && fastDepartures == 3 && fastStops == 7 && fastFirstArrivals == 1,
              "an interrupted arrival cannot settle or sound again after the latest target arrives")
        interrupted.show(b, reduceMotion: false)
        try await waitUntil { interrupted.phase == .black }
        let cuesBeforeExit = fastDepartures
        let stopsBeforeExit = fastStops
        interrupted.cancel()
        try await Task.sleep(for: .milliseconds(220))
        check(interrupted.photo == nil && interrupted.shutter == 0 && fastDepartures == cuesBeforeExit && fastStops == stopsBeforeExit + 1,
              "exiting during black stops audio and prevents a pending reveal or later cue")

        interrupted.show(a, reduceMotion: false)
        interrupted.beginPresentation()
        await interrupted.waitForPendingLoad()
        interrupted.show(b, reduceMotion: false)
        try await waitUntil { interrupted.phase == .departing }
        let departureCuesBeforeExit = fastDepartures
        let departureStopsBeforeExit = fastStops
        interrupted.cancel()
        try await Task.sleep(for: .milliseconds(220))
        check(interrupted.photo == nil && interrupted.shutter == 0 && fastDepartures == departureCuesBeforeExit &&
              fastStops == departureStopsBeforeExit + 1,
              "exiting during departure stops the active recording and rejects all later stages")

        var failedCues = 0
        let failedPresentation = SlideshowPlayback(loader: { $0 == a ? nil : photo($0) },
                                                   outgoingSound: { failedCues += 1 },
                                                   firstArrivalSound: { failedCues += 1 })
        failedPresentation.beginPresentation()
        failedPresentation.show(a, reduceMotion: false)
        await failedPresentation.waitForPendingLoad()
        check(failedPresentation.failed && failedPresentation.shutter == 0 && failedCues == 0,
              "an unreadable photo remains dark and never emits a movement cue")
        failedPresentation.show(b, reduceMotion: true)
        await failedPresentation.waitForPendingLoad()
        check(failedCues == 1 && failedPresentation.photo?.url == b,
              "an unreadable initial photo does not consume the first-arrival sound")
        failedPresentation.cancel()

        var reducedCues = 0, reducedFirstArrivals = 0, reducedStops = 0
        let reduced = SlideshowPlayback(loader: { photo($0) }, outgoingSound: { reducedCues += 1 },
                                        firstArrivalSound: { reducedFirstArrivals += 1 },
                                        stopSound: { reducedStops += 1 })
        reduced.beginPresentation()
        reduced.show(a, reduceMotion: true)
        await reduced.waitForPendingLoad()
        check(reduced.photo?.url == a && reduced.transport == 0 && reduced.shutter == 1 && reduced.focus == 1,
              "reduced motion projects directly without a slide travel or focus animation")
        check(reducedCues == 0 && reducedFirstArrivals == 1, "reduced motion uses the same latter-half first-arrival cue")
        reduced.show(b, reduceMotion: true)
        await reduced.waitForPendingLoad()
        check(reduced.photo?.url == b && reduced.phase == .settled && reducedCues == 1 && reducedStops == 2 && reducedFirstArrivals == 1,
              "reduced motion plays one uncut recording when replacing an already projected slide")
        reduced.cancel()

        let slowGate = ProjectionGate()
        var slowDepartures = 0, slowStops = 0
        let slowPlayback = SlideshowPlayback(loader: { url in
            if url == a { return photo(a) }
            return await slowGate.load(url)
        }, outgoingSound: { slowDepartures += 1 }, stopSound: { slowStops += 1 })
        slowPlayback.show(a, reduceMotion: false)
        await slowPlayback.waitForPendingLoad()
        slowPlayback.beginPresentation()
        await slowPlayback.waitForPendingLoad()
        slowPlayback.show(b, reduceMotion: false)
        try await waitUntil { slowGate.started.contains(b) }
        try await Task.sleep(for: .milliseconds(740))
        check(slowPlayback.photo?.url == a && slowPlayback.shutter == 1 && slowPlayback.transport == 0 &&
              slowDepartures == 0 && slowStops == 2,
              "a slow decoder keeps the old projection still and never plays the next mechanical cue early")
        slowGate.complete(photo(b))
        await slowPlayback.waitForPendingLoad()
        check(slowPlayback.photo?.url == b && slowPlayback.transport == 0 && slowDepartures == 1 && slowStops == 2,
              "a slow slide starts its one continuous shutter recording only after its data becomes ready")
        slowPlayback.cancel()

        let audioGate = ProjectionGate()
        var audioReadyFirstCues = 0, imageLoadedDuringAudioPreparation = false
        let awaitingAudio = SlideshowPlayback(loader: { url in
            imageLoadedDuringAudioPreparation = true
            return photo(url)
        }, firstArrivalSound: { audioReadyFirstCues += 1 },
           prepareSound: { _ = await audioGate.load(a) })
        awaitingAudio.beginPresentation()
        awaitingAudio.show(a, reduceMotion: true)
        try await waitUntil { audioGate.started.contains(a) && imageLoadedDuringAudioPreparation }
        check(awaitingAudio.shutter == 0 && audioReadyFirstCues == 0,
              "photo loading runs alongside audio preparation, and first arrival waits silently for both")
        audioGate.complete(photo(a))
        await awaitingAudio.waitForPendingLoad()
        check(awaitingAudio.phase == .settled && audioReadyFirstCues == 1,
              "prepared audio and photo start the first reveal and cue together")
        awaitingAudio.cancel()

        let cancelledAudioGate = ProjectionGate()
        var cancelledAudioCues = 0
        let cancelledAudio = SlideshowPlayback(loader: { photo($0) },
                                               firstArrivalSound: { cancelledAudioCues += 1 },
                                               prepareSound: { _ = await cancelledAudioGate.load(a) })
        cancelledAudio.beginPresentation()
        cancelledAudio.show(a, reduceMotion: true)
        try await waitUntil { cancelledAudioGate.started.contains(a) }
        cancelledAudio.cancel()
        cancelledAudioGate.complete(photo(a))
        try await waitUntil { cancelledAudioGate.returned.contains(a) }
        try await settleCallbacks()
        check(cancelledAudio.photo == nil && cancelledAudio.shutter == 0 && cancelledAudioCues == 0,
              "audio preparation finishing after exit cannot restore a photo or play a stale first cue")

        let sleeve = CGRect(x: 120, y: 740, width: 90, height: 56)
        let slot = CGPoint(x: 600, y: 560)
        let entryStart = SlideshowEntryPose(frame: sleeve, destination: slot, index: 0, progress: 0)
        let entryArc = SlideshowEntryPose(frame: sleeve, destination: slot, index: 0, progress: 0.5)
        let entryEnd = SlideshowEntryPose(frame: sleeve, destination: slot, index: 0, progress: 1)
        check(entryStart.center == CGPoint(x: sleeve.midX, y: sleeve.midY) && entryStart.scale == 1 && entryStart.opacity == 1,
              "collection starts at the real visible sleeve without an initial position jump")
        check(entryArc.center.y < slot.y && entryArc.opacity == 1 && !entryArc.behindFront,
              "each collected film remains visible along an upper arc before reaching the machine")
        check(entryEnd.center == slot && entryEnd.behindFront && entryEnd.opacity == 0,
              "collected films disappear only after reaching the machine behind its front panel")

        let stage = CGSize(width: 1200, height: 900), slideSize = CGSize(width: 1008, height: 604.8)
        let resting = ProjectionTravelPose.at(0, container: stage, image: slideSize)
        let incoming = ProjectionTravelPose.at(-1, container: stage, image: slideSize)
        let arc = ProjectionTravelPose.at(-0.5, container: stage, image: slideSize)
        let outgoing = ProjectionTravelPose.at(1, container: stage, image: slideSize)
        check(resting.x == 0 && resting.y == 0 && resting.angle == 0,
              "a settled slide is centred without a remaining tilt")
        check(incoming.x + slideSize.width / 2 < -stage.width / 2 && incoming.angle < 0,
              "a new slide begins outside the left side of the screen with a small tilt")
        check(arc.x > incoming.x && arc.x < 0 && arc.y < incoming.y,
              "the new slide follows an upper arc towards the centre")
        check(outgoing.x + slideSize.width / 2 < -stage.width / 2 && outgoing.y > 0 && outgoing.angle > 0,
              "the outgoing slide leaves the left side with a small downward tilt before black")

        let renderer = SlideshowProjectionStore()
        guard let rendered = await renderer.render(source, url: a) else {
            preconditionFailure("in-memory projection rendering failed")
        }
        check(rendered.url == a && rendered.sharp.width == source.width && rendered.sharp.height == source.height,
              "projection rendering preserves image identity and raster dimensions")
        let baseline = NSBitmapImageRep(cgImage: source)
        let sharp = NSBitmapImageRep(cgImage: rendered.sharp)
        let soft = NSBitmapImageRep(cgImage: rendered.soft)
        for (x, y) in [(250, 150), (750, 150), (250, 450), (750, 450)] {
            check(colorDifference(color(sharp, x, y), color(baseline, x, y)) < 0.01,
                  "quadrant at \(x),\(y) retains its source color and orientation")
        }
        for (x, y) in [(499, 299), (500, 299), (499, 300), (500, 300)] {
            check(colorDifference(color(sharp, x, y), color(baseline, x, y)) < 0.01,
                  "the centre remains sharp and color-preserving at \(x),\(y)")
        }
        let leftAlpha = (0...8).map { color(sharp, $0, 300).alphaComponent }
        check(leftAlpha[0] < 0.01 && leftAlpha[1] > leftAlpha[0] && leftAlpha[2] > leftAlpha[1],
              "the outer alpha edge fades inward gradually")
        check(leftAlpha[8] > 0.99 && color(sharp, 50, 50).alphaComponent > 0.99,
              "edge feathering stays narrow and the interior remains opaque")
        check(color(sharp, 500, 0).alphaComponent < 0.01 && color(sharp, 500, 8).alphaComponent > 0.99 &&
              color(sharp, 999, 300).alphaComponent < 0.01 && color(sharp, 500, 599).alphaComponent < 0.01,
              "all four sides have the same narrow transparent boundary")
        check(color(sharp, 0, 0).alphaComponent < 0.01 && color(sharp, 999, 599).alphaComponent < 0.01,
              "projection corners also fade to transparent")
        check(abs(color(soft, 1, 300).alphaComponent - color(sharp, 1, 300).alphaComponent) < 0.01 &&
              color(soft, 500, 300).alphaComponent > 0.99,
              "the focus bitmap shares the same edge alpha without dimming the centre")
        check(colorDifference(color(soft, 499, 150), color(baseline, 499, 150)) > 0.03,
              "the temporary focus bitmap softens an internal edge while the sharp bitmap does not")
        check(colorDifference(color(sharp, 50, 50), color(baseline, 50, 50)) > 0.015 &&
              color(sharp, 50, 50).redComponent < color(baseline, 50, 50).redComponent,
              "the lens gently dims outer corners while the central colour checks remain unchanged")
        guard let glowImage = rendered.glow else { preconditionFailure("projection colour spill was not rendered") }
        let glow = NSBitmapImageRep(cgImage: glowImage)
        check(glowImage.width <= 610 && glowImage.height <= 610 && rendered.glowOutset >= 0.10,
              "projection spill is cached at a bounded small resolution with outside padding")
        check(color(glow, 0, glowImage.height / 2).alphaComponent < 0.01 &&
              color(glow, glowImage.width / 2, 0).alphaComponent < 0.01,
              "the cached colour spill dies away before its outer rectangle")
        check(color(glow, 40, glowImage.height / 2).alphaComponent > 0.01,
              "the cached spill carries light beyond the original left aperture edge")

        // Inspect the actual bundled recording without opening an audio output device.
        guard let shutterURL = SlideshowSoundResource.url() else {
            preconditionFailure("the check executable must contain ShutterClick.wav")
        }
        let shutterData = try Data(contentsOf: shutterURL)
        let shutterDigest = SHA256.hash(data: shutterData).map { String(format: "%02x", $0) }.joined()
        check(shutterDigest == "5534a1a4f544100b73a72ef31e8853543dba20c66f1db9186cfb147ae162aa25",
              "the bundled sound matches the selected Jianying shutter recording exactly")
        let shutterAudio = try AVAudioFile(forReading: shutterURL)
        check(shutterAudio.fileFormat.sampleRate == 48_000 && shutterAudio.fileFormat.channelCount == 2 &&
              shutterAudio.length == 9_126,
              "the recording preserves both channels, 48kHz and the complete 190.125ms source duration")
        guard let shutterBuffer = AVAudioPCMBuffer(pcmFormat: shutterAudio.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(shutterAudio.length)) else {
            preconditionFailure("the selected shutter recording must decode")
        }
        try shutterAudio.read(into: shutterBuffer)
        guard let channels = shutterBuffer.floatChannelData else {
            preconditionFailure("the recording must provide decoded PCM samples")
        }
        let channelSamples = (0..<Int(shutterBuffer.format.channelCount)).flatMap { channel in
            Array(UnsafeBufferPointer(start: channels[channel], count: Int(shutterBuffer.frameLength)))
        }
        check(shutterBuffer.frameLength == 9_126 && channelSamples.allSatisfy { $0.isFinite && abs($0) <= 1 } &&
              channelSamples.contains { abs($0) > 0.05 },
              "the whole shutter recording decodes to non-silent bounded audio")
        check(SlideshowSoundResource.playbackVolume == 0.20,
              "first arrival and full shutter share the quieter playback volume")
        for (name, dryFrames) in [("ShutterClickRoom", 9_126), ("ShutterArrivalRoom", 4_563)] {
            guard let roomURL = SlideshowSoundResource.url(named: name) else {
                preconditionFailure("the processed shutter resource must be bundled")
            }
            let room = try AVAudioFile(forReading: roomURL)
            check(room.length == dryFrames + 8_640 && room.fileFormat.sampleRate == 48_000 && room.fileFormat.channelCount == 2,
                  "\(name) keeps its selected dry interval and adds exactly 180ms of room tail")
            guard let buffer = AVAudioPCMBuffer(pcmFormat: room.processingFormat, frameCapacity: AVAudioFrameCount(room.length)) else {
                preconditionFailure("the room recording must decode")
            }
            try room.read(into: buffer)
            guard let samples = buffer.floatChannelData else { preconditionFailure("the room recording must supply PCM") }
            let allSamples = (0..<Int(buffer.format.channelCount)).flatMap { channel in
                Array(UnsafeBufferPointer(start: samples[channel], count: Int(buffer.frameLength)))
            }
            check(allSamples.allSatisfy { $0.isFinite && abs($0) < 0.92 } && allSamples.contains { abs($0) > 0.05 },
                  "\(name) contains a clear click with peak headroom")
            let tail = Array(UnsafeBufferPointer(start: samples[0] + dryFrames, count: 8_640))
            check(tail.contains { abs($0) > 0.0001 } && tail.last == 0 && samples[0][0] == 0,
                  "\(name) has a quiet reflection tail and click-free endpoints")
            if let appPath = CommandLine.arguments.dropFirst().first {
                guard let bundle = Bundle(path: appPath), let url = SlideshowSoundResource.url(named: name, in: bundle) else {
                    preconditionFailure("the standalone app must bundle both room recordings")
                }
                let packaged = try Data(contentsOf: url)
                let expected = try Data(contentsOf: roomURL)
                check(url.standardizedFileURL.path.hasPrefix(bundle.bundleURL.standardizedFileURL.path + "/") && packaged == expected,
                      "the standalone app contains the exact \(name) recording inside its bundle")
            }
        }
        // Optional standalone app verification uses the same production resolver.
        if let appPath = CommandLine.arguments.dropFirst().first {
            guard let appBundle = Bundle(path: appPath),
                  let appAudioURL = SlideshowSoundResource.url(in: appBundle) else {
                preconditionFailure("the standalone app must resolve its own bundled shutter audio")
            }
            check(appAudioURL.standardizedFileURL.path.hasPrefix(appBundle.bundleURL.standardizedFileURL.path + "/"),
                  "the standalone app resolves audio inside its own bundle")
            let appAudio = try Data(contentsOf: appAudioURL)
            check(appAudio == shutterData, "the standalone app contains the complete selected recording")
        }

        let portraitImage = makeQuadrants(width: 600, height: 1000)
        let portrait = ProjectionPhoto(url: b, sharp: portraitImage, soft: portraitImage)
        for container in [CGSize(width: 1180, height: 900), CGSize(width: 840, height: 640), CGSize(width: 900, height: 1500)] {
            for candidate in [rendered, portrait] {
                let fitted = candidate.fittedSize(in: container)
                check(fitted.width <= container.width * 0.84 + 0.001 && fitted.height <= container.height * 0.84 + 0.001 &&
                      fitted.width > 0 && fitted.height > 0 && abs(fitted.width / fitted.height - candidate.aspect) < 0.0001,
                      "landscape/portrait projection keeps its aspect and black margins in \(Int(container.width))x\(Int(container.height))")
                let departure = ProjectionTravelPose.at(1, container: container, image: fitted)
                let angle = CGFloat(departure.angle) * .pi / 180
                let halfWidth = (fitted.width * abs(cos(angle)) + fitted.height * abs(sin(angle))) / 2
                check(departure.x + halfWidth < -container.width / 2,
                      "the tilted outgoing photo fully clears the screen in \(Int(container.width))x\(Int(container.height))")
            }
        }

        let empty = TableModel(restore: false)
        empty.enterSlideshow()
        empty.nextSlide(); empty.previousSlide()
        check(!empty.slideshowMode && empty.currentSlideURL == nil && empty.nextSlideURL == nil,
              "an empty library cannot enter slideshow or create a navigation target")
        for initiallyLit in [false, true] {
            let model = TableModel(restore: false)
            model.photos = [a, b, c].map { Photo(url: $0) }
            let selected = model.layout.place(a, x: 0.3, y: 0.6)
            model.selectedID = selected
            model.loupeEnabled = true
            model.isLit = initiallyLit
            model.pan = CGPoint(x: 28, y: -14)
            model.zoom = 1.7
            let layout = model.layout
            let lightStarted = model.lightStartedAt
            model.enterSlideshow()
            check(model.slideshowMode && model.slideshowOrder.count == 3 && Set(model.slideshowOrder) == Set([a, b, c]),
                  "slideshow queues every library photo once in a randomized order")
            let first = model.currentSlideURL
            check(model.nextSlideURL == model.slideshowOrder[1], "next-slide preload target follows the randomized queue")
            model.previousSlide()
            check(model.currentSlideURL == model.slideshowOrder.last, "previous navigation wraps to the last photo")
            model.nextSlide()
            check(model.currentSlideURL == first, "forward navigation returns from the last photo to the first")
            for _ in 0..<3 { model.nextSlide() }
            check(model.currentSlideURL == first, "forward navigation loops after one complete queue")
            check(model.layout == layout && model.selectedID == selected && model.isLit == initiallyLit &&
                  model.lightStartedAt == lightStarted && model.loupeEnabled && model.pan == CGPoint(x: 28, y: -14) && model.zoom == 1.7,
                  "slideshow navigation preserves table layout, selection, lamp, lens and camera")
            model.exitSlideshow()
            check(!model.slideshowMode && model.currentSlideURL == nil && model.nextSlideURL == nil && model.slideshowOrder.isEmpty,
                  "exit clears only the transient slideshow queue")
            check(model.layout == layout && model.selectedID == selected && model.isLit == initiallyLit && model.loupeEnabled,
                  "returning to the table preserves its viewing state")
        }
        // Isolate source metadata and all five disk-cache layers from the users
        // originals/cache. Invalid image bytes guarantee this exercises disk hits.
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighttable-slideshow-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sourceDirectory = temporaryRoot.appendingPathComponent("metadata-only", isDirectory: true)
        let cacheDirectory = temporaryRoot.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let tinyImage = makeQuadrants(width: 12, height: 8)
        let synthetic = PhotoPreview(source: tinyImage, lit: tinyImage, dark: tinyImage, flare: tinyImage, boosted: tinyImage)
        var cacheURLs: [URL] = []
        for index in 0..<13 {
            let url = sourceDirectory.appendingPathComponent("metadata-\(index).jpg")
            try Data("metadata-only-\(index)".utf8).write(to: url)
            PhotoPreviewDiskCache.save(synthetic, for: url, maxPixel: 128, root: cacheDirectory)
            cacheURLs.append(url)
        }
        let cacheStore = PhotoStore(cacheDirectory: cacheDirectory)
        var references: [WeakPhotoPreview] = []
        for url in cacheURLs.prefix(12) {
            guard let reference = await weakPreview(in: cacheStore, url: url) else {
                preconditionFailure("synthetic preview was not loaded from the isolated disk cache")
            }
            references.append(reference)
        }
        check(references.allSatisfy { $0.value != nil }, "the first twelve disk-loaded previews remain in the memory cache")
        guard let thirteenth = await weakPreview(in: cacheStore, url: cacheURLs[12]) else {
            preconditionFailure("thirteenth synthetic disk preview failed to load")
        }
        references.append(thirteenth)
        check(references[0].value == nil, "the thirteenth disk hit releases the oldest memory-cached preview")
        check(references.dropFirst().allSatisfy { $0.value != nil }, "disk-hit eviction retains exactly the twelve recent preview objects")
        let latest = await cacheStore.preview(cacheURLs[12], maxPixel: 128)
        check(latest != nil && latest === thirteenth.value, "a recent preview reuses the identical in-memory object")
        let reread = await cacheStore.preview(cacheURLs[0], maxPixel: 128)
        check(reread?.source.width == 12 && reread?.source.height == 8,
              "an evicted preview can be read again from its five disk-cache layers")
        check(references[1].value == nil, "reloading the oldest preview evicts the next least-recent disk-loaded object")
        check(try Data(contentsOf: cacheURLs[0]) == Data("metadata-only-0".utf8),
              "preview cache reads leave the isolated source metadata file unchanged")

        print("Slideshow checks: \(count) passed; no NSApplication or NSWindow was created.")
    }

    // Keep the strong await result inside a completed helper frame so an async
    // callers local lifetime cannot accidentally keep the oldest preview alive.
    private static func weakPreview(in store: PhotoStore, url: URL) async -> WeakPhotoPreview? {
        guard let value = await store.preview(url, maxPixel: 128) else { return nil }
        return WeakPhotoPreview(value)
    }

    private static func makeQuadrants(width: Int, height: Int) -> CGImage {
        let colors: [[UInt8]] = [[222, 35, 46, 255], [22, 194, 77, 255], [30, 68, 218, 255], [204, 176, 44, 255]]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = colors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)]
                let offset = (y * width + x) * 4
                bytes.replaceSubrange(offset..<(offset + 4), with: value)
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func color(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }

    private static func colorDifference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
    }
}
