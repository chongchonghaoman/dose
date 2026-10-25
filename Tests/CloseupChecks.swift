import AppKit
import SwiftUI
import LightTableCore

private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

private struct PreferenceProbe: View {
    let placement: SlidePlacement
    let id: UUID
    let receive: ([UUID: SlidePlacement]) -> Void
    var body: some View {
        Color.clear.preference(key: SlidePresentationKey.self, value: [id: placement])
            .onPreferenceChange(SlidePresentationKey.self, perform: receive)
    }
}

private actor RasterGate {
    private(set) var requests: [LoupeRasterRequest] = []
    private var continuation: CheckedContinuation<CGImage?, Never>?
    var count: Int { requests.count }
    func render(_ request: LoupeRasterRequest) async -> CGImage? {
        requests.append(request)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ image: CGImage) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: image)
    }
}

@main struct CloseupChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS \(message)")
        }
        let point = CGPoint(x: 400, y: 300)
        let board = CGSize(width: 1000, height: 700)
        let original = LoupeRenderer.sourceViewport(point: point, diameter: LoupeGeometry.diameter,
                                                    magnification: LoupeGeometry.magnification)
        check(LoupeGeometry.magnification == 1.5, "finding lens uses 1.5x")
        check(LoupeGeometry.rasterDiameter(in: CGSize(width: 2200, height: 1100), closeViewing: false) == 260,
              "ordinary pointer movement renders only the visible lens even in a large window")
        for window in [CGSize(width: 1180, height: 900), CGSize(width: 840, height: 640), CGSize(width: 2200, height: 1100)] {
            let diameter = LoupeGeometry.closeDiameter(in: window)
            check(LoupeGeometry.rasterDiameter(in: window, closeViewing: true) == diameter,
                  "held-space viewing retains full sampling resolution at \(Int(window.width))pt")
            let close = LoupeRenderer.sourceViewport(point: point, diameter: diameter,
                                                    magnification: LoupeGeometry.magnification(for: diameter))
            check(abs(close.width - original.width) < 1e-8 && abs(close.minX - original.minX) < 1e-8 &&
                  diameter <= min(window.width, window.height), "close view retains source field at \(Int(window.width))pt")
        }

        let beginning = LoupeDepth(progress: 0, finalScale: 3)
        let middle = LoupeDepth(progress: 0.5, finalScale: 3)
        let ending = LoupeDepth(progress: 1, finalScale: 3)
        check(beginning.scale == 1 && beginning.apertureScale == 1 && beginning.surround == 0,
              "approach begins exactly at the original lens without a jump")
        check(middle.scale > middle.apertureScale && middle.scale / middle.apertureScale < 1.1,
              "film and rim share the approach with only a modest distance-dependent difference")
        let early = LoupeDepth(progress: 0.02, finalScale: 3)
        check(early.scale > 1 && early.apertureScale > 1,
              "film and circular frame both grow from the start without a delayed opening")
        let late = LoupeDepth(progress: 0.95, finalScale: 3)
        check(late.scale < ending.scale && late.apertureScale < ending.apertureScale,
              "both layers keep advancing until arrival rather than stopping early")
        check(abs(ending.scale - 3) < 1e-8 && abs(ending.apertureScale - 3) < 1e-8 && ending.surround == 1,
              "arrival settles at the original field, clear image, and dark surround")
        var lastSize: CGFloat = 0
        var lastAperture: CGFloat = 0
        var continuousAdvance = true
        var covered = true
        for step in 0...100 {
            let depth = LoupeDepth(progress: CGFloat(step) / 100, finalScale: 3)
            continuousAdvance = continuousAdvance && depth.scale >= lastSize && depth.apertureScale >= lastAperture
            covered = covered && depth.scale >= depth.apertureScale
            lastSize = depth.scale
            lastAperture = depth.apertureScale
        }
        check(continuousAdvance, "101 samples advance film and aperture without overshoot or image recoil")
        check(covered, "film always covers the aperture with no uncovered ring")

        var smoothEdges = true
        var forwardEdges = true
        var alignedEdges = true
        var smoothScales = true
        for window in [CGSize(width: 840, height: 640), CGSize(width: 1180, height: 900), CGSize(width: 2200, height: 1100)] {
            let finalScale = LoupeGeometry.closeDiameter(in: window) / LoupeGeometry.diameter
            for origin in [CGPoint(x: 20, y: window.height / 2),
                           CGPoint(x: window.width - 20, y: window.height / 2),
                           CGPoint(x: 20, y: 20), CGPoint(x: window.width - 20, y: window.height - 20)] {
                let target = LoupeGeometry.closeCenter(from: origin, in: window)
                func center(_ p: CGFloat) -> CGPoint {
                    LoupeDepth(progress: p, finalScale: finalScale).rearCenter(origin: origin, target: target)
                }
                let h: CGFloat = 0.00001
                var previousDistance = hypot(target.x - origin.x, target.y - origin.y)
                for step in 0...2000 {
                    let p = CGFloat(step) / 2000
                    let a = center(p - h), b = center(p), c = center(p + h)
                    let velocityBreak = hypot(c.x - 2 * b.x + a.x, c.y - 2 * b.y + a.y) / h
                    smoothEdges = smoothEdges && velocityBreak < 0.5
                    let distance = hypot(target.x - b.x, target.y - b.y)
                    forwardEdges = forwardEdges && distance <= previousDistance + 0.00001
                    previousDistance = distance
                    let depth = LoupeDepth(progress: p, finalScale: finalScale)
                    let front = CGPoint(x: origin.x + (target.x - origin.x) * depth.apertureTravel,
                                        y: origin.y + (target.y - origin.y) * depth.apertureTravel)
                    alignedEdges = alignedEdges && hypot(b.x - front.x, b.y - front.y) < 0.00001
                    let left = LoupeDepth(progress: p - h, finalScale: finalScale)
                    let right = LoupeDepth(progress: p + h, finalScale: finalScale)
                    for (l, m, r) in [(left.scale, depth.scale, right.scale),
                                      (left.apertureScale, depth.apertureScale, right.apertureScale)] {
                        smoothScales = smoothScales && abs(r - 2 * m + l) / h < 0.02
                    }
                }
                forwardEdges = forwardEdges && hypot(center(0).x - origin.x, center(0).y - origin.y) < 0.00001 &&
                    hypot(center(1).x - target.x, center(1).y - target.y) < 0.00001
            }
        }
        check(smoothEdges, "side and corner avoidance has continuous velocity throughout approach and return")
        check(forwardEdges, "side and corner approach keeps its endpoints and never recoils")
        check(alignedEdges, "film and aperture share the optical axis while avoiding window edges")
        check(smoothScales, "shared film and circle timeline has no velocity breaks")
        for p: CGFloat in [0, 0.14, 0.4, 0.82, 1] {
            let flat = LoupeDepth(progress: p, finalScale: 1)
            check(flat.scale == 1 && flat.apertureScale == 1, "small windows never invent an extra magnification at progress \(p)")
        }

        for window in [CGSize(width: 840, height: 640), CGSize(width: 1180, height: 900),
                       CGSize(width: 2200, height: 1100), CGSize(width: 4000, height: 3000)] {
            let closeDiameter = LoupeGeometry.closeDiameter(in: window)
            let ordinary = LoupeSampling(in: window, closeViewing: false, mode: .eight, progress: 0)
            check(ordinary.diameter == 260 && ordinary.magnification == 1.5 && ordinary.contentScale == 1,
                  "8x preset leaves ordinary 1.5x sampling unchanged at \(Int(window.width))pt")
            let end = LoupeSampling(in: window, closeViewing: true, mode: .eight, progress: 1)
            check(abs(end.magnification - 8) < 1e-8 && end.diameter == closeDiameter && end.contentScale == 1,
                  "8x samples original pixels at exactly 8x within the existing drawable at \(Int(window.width))pt")
            let returning = LoupeSampling(in: window, closeViewing: true, mode: .eight, progress: 0)
            check(abs(returning.magnification * 260 / returning.diameter - 1.5) < 1e-8,
                  "return reaches 1.5x before dropping the large raster at \(Int(window.width))pt")
            let available = LoupeGeometry.sourceViewport(point: point, in: window, closeViewing: true, mode: .eight)
            var continuous = true
            var containsField = true
            var unchangedOriginal = true
            var previous: CGFloat = 1.5
            for step in 0...100 {
                let progress = CGFloat(step) / 100
                let sample = LoupeSampling(in: window, closeViewing: true, mode: .eight, progress: progress)
                let displayedDiameter = 260 * sample.depth.apertureScale
                let displayedMagnification = sample.magnification * displayedDiameter / sample.diameter
                continuous = continuous && displayedMagnification >= previous - 1e-8 && displayedMagnification <= 8 + 1e-8
                previous = displayedMagnification
                let field = LoupeRenderer.sourceViewport(point: point, diameter: displayedDiameter, magnification: displayedMagnification)
                containsField = containsField && available.insetBy(dx: -0.001, dy: -0.001).contains(field)
                let originalSample = LoupeSampling(in: window, closeViewing: true, mode: .original, progress: progress)
                let originalDepth = LoupeDepth(progress: progress, finalScale: closeDiameter / 260)
                unchangedOriginal = unchangedOriginal && originalSample.magnification == LoupeGeometry.magnification(for: closeDiameter)
                    && originalSample.contentScale == originalDepth.scale / originalDepth.apertureScale
            }
            check(continuous, "8x approach and reversed return stay continuous and never overshoot at \(Int(window.width))pt")
            check(containsField, "scene selection covers every intermediate field, including windows above native 8x, at \(Int(window.width))pt")
            check(unchangedOriginal, "original mode retains the existing fixed sampling and layer animation at \(Int(window.width))pt")
        }

        for window in [CGSize(width: 840, height: 640), CGSize(width: 1180, height: 900), CGSize(width: 4000, height: 3000)] {
            let native = LoupeCloseMagnification.original.magnification(in: window)
            let originalField = LoupeGeometry.sourceViewport(point: point, in: window, closeViewing: true, mode: .original)
            let eightField = LoupeGeometry.sourceViewport(point: point, in: window, closeViewing: true, mode: .eight)
            check(originalField == eightField, "changing focal target retains both endpoint scenes at \(Int(window.width))pt")
            var focalScale = true, boundedRaster = true, fieldCoverage = true, coveredClip = true
            for step in 0...100 {
                let blend = CGFloat(step) / 100
                let sample = LoupeSampling(in: window, closeViewing: true, magnificationBlend: blend, progress: 1)
                let expected = native * pow(8 / native, blend)
                focalScale = focalScale && abs(sample.magnification - expected) < 1e-8
                boundedRaster = boundedRaster && sample.diameter == LoupeGeometry.closeDiameter(in: window)
                    && sample.depth.apertureScale == LoupeGeometry.closeDiameter(in: window) / 260
                let field = LoupeRenderer.sourceViewport(point: point, diameter: sample.diameter, magnification: sample.magnification)
                fieldCoverage = fieldCoverage && originalField.insetBy(dx: -0.001, dy: -0.001).contains(field)
                for progress: CGFloat in [0, 0.2, 0.5, 0.8, 1] {
                    let moving = LoupeSampling(in: window, closeViewing: true, magnificationBlend: blend, progress: progress)
                    coveredClip = coveredClip && moving.contentScale >= 1 && moving.magnification.isFinite
                    let shownDiameter = 260 * moving.depth.apertureScale
                    let shownMagnification = moving.magnification * moving.contentScale * shownDiameter / moving.diameter
                    let movingField = LoupeRenderer.sourceViewport(point: point, diameter: shownDiameter, magnification: shownMagnification)
                    fieldCoverage = fieldCoverage && originalField.insetBy(dx: -0.001, dy: -0.001).contains(movingField)
                }
            }
            check(focalScale, "focal transition follows continuous proportional magnification in both directions at \(Int(window.width))pt")
            check(boundedRaster, "focal switching keeps the aperture and drawable size fixed at \(Int(window.width))pt")
            check(fieldCoverage, "scene culling covers switching during approach and return at \(Int(window.width))pt")
            check(coveredClip, "focal switching never shrinks the source below the lens clip at \(Int(window.width))pt")
        }
        let blendScene = LoupeSceneInput(photos: [], point: point, panelBounds: nil, transmission: 1, flare: 0, brightness: 1)
        var approach = LoupeApproach(scene: blendScene, origin: point, size: board, magnificationBlend: 1,
                                     closeViewing: true, displayScale: 2, progress: 1)
        approach.animatableData = AnimatablePair(0.7, 0.38)
        check(approach.progress == 0.7 && approach.magnificationBlend == 0.38 && approach.scene.point == point,
              "approach and focal ratio are independent animatable values with a fixed sampling point")
        approach.animatableData = AnimatablePair(0.7, 0.35)
        check(approach.magnificationBlend == 0.35 && approach.progress == 0.7,
              "a focal reversal can continue from an intermediate displayed value without resetting approach")
        let invalidBlend = LoupeSampling(in: board, closeViewing: true, magnificationBlend: .nan, progress: 1)
        check(invalidBlend.magnification.isFinite && invalidBlend.contentScale.isFinite, "invalid focal ratio falls back to the original finite sampling")

        let slide = Slide(url: URL(fileURLWithPath: "/in-memory.png"), x: 0.5, y: 0.5, width: 0.3)
        let baseline = SlidePresentation.placement(slide, board: board, aspect: 1.5, zoom: 1)
        let enlarged = SlidePresentation.placement(slide, board: board, aspect: 1.5, zoom: 1, magnification: 1.8)
        let rotated = SlidePresentation.placement(slide, board: board, aspect: 1.5, zoom: 1, magnification: 1.8, rotation: 37)
        check(abs(enlarged.width / baseline.width - 1.8) < 1e-8 && slide.width == 0.3,
              "transient pinch enlarges displayed geometry before document commit")
        check(rotated.angle == 37 && abs(rotated.width - enlarged.width) < 1e-8,
              "simultaneous rotation and pinch share displayed geometry")

        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 300, y: 0, width: 300, height: 400))
        let image = ctx.makeImage()!
        let preview = PhotoPreview(source: image, lit: image, dark: image, flare: image)
        let eightScene = LoupeSceneInput(photos: [LoupeScenePhoto(preview: preview,
            center: CGPoint(x: 300, y: 200), imageSize: CGSize(width: 600, height: 400))],
            point: CGPoint(x: 310, y: 200), panelBounds: nil, transmission: 1, flare: 0, brightness: 1)
        let eightInput = LoupeSampling(in: CGSize(width: 840, height: 640), closeViewing: true,
                                      mode: .eight, progress: 1).input(scene: eightScene, displayScale: 1)
        let eightRequest = LoupeRasterRequest(eightInput)
        let quickEight = eightRequest.quick
        check(eightRequest.magnification == eightInput.magnification && eightRequest.diameter == eightInput.diameter,
              "GPU and software fallback receive the same 8x sampling geometry")
        check(abs(quickEight.diameter / quickEight.magnification! - eightRequest.diameter / eightRequest.magnification!) < 1e-8,
              "quick 8x fallback preserves the final source field when lowering resolution")
        var glassRequest = eightRequest
        glassRequest.refractionScale = 0.4
        check(glassRequest.quick.refractionScale == 0.4, "quick fallback retains glass refraction strength")
        let eightImage = LoupeRenderer.shared.render(photos: eightScene.photos, point: eightScene.point,
            diameter: eightInput.diameter, magnification: eightInput.magnification, displayScale: 1,
            transmission: 1, flare: 0, brightness: 1)!
        let eightBitmap = NSBitmapImageRep(cgImage: eightImage)
        let near = eightBitmap.colorAt(x: eightImage.width / 2 - 40, y: eightImage.height / 2)!.usingColorSpace(.sRGB)!
        let far = eightBitmap.colorAt(x: eightImage.width / 2 - 100, y: eightImage.height / 2)!.usingColorSpace(.sRGB)!
        check(near.blueComponent > 0.7 && far.redComponent > 0.7,
              "rendered 8x source boundary lies 80 pixels from the pointer, without a flip")
        func photo(_ placement: SlidePlacement) -> LoupeScenePhoto {
            LoupeScenePhoto(preview: preview, center: CGPoint(x: placement.x, y: placement.y),
                            imageSize: CGSize(width: placement.width, height: placement.height), angle: placement.angle)
        }
        let samplePoint = CGPoint(x: baseline.x + baseline.width * 0.65, y: baseline.y)
        func render(_ p: SlidePlacement, diameter: CGFloat = 260) -> CGImage {
            LoupeRenderer.shared.render(photos: [photo(p)], point: samplePoint,
                diameter: diameter, magnification: LoupeGeometry.magnification(for: diameter), displayScale: 1,
                transmission: 1, flare: 0, brightness: 1)!
        }
        func pixel(_ image: CGImage) -> NSColor {
            NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)!.usingColorSpace(.sRGB)!
        }
        let before = pixel(render(baseline)), during = pixel(render(enlarged))
        check(before.redComponent > 0.7 && before.blueComponent > 0.7 && during.redComponent < 0.2 && during.blueComponent > 0.7,
              "lens follows pinch before commit: blank becomes the newly enlarged blue photo")
        let close = render(enlarged, diameter: 810)
        check(close.width == 810 && abs(pixel(close).blueComponent - during.blueComponent) < 0.01,
              "close lens samples final resolution and preserves the same source point")

        let gate = RasterGate()
        let raster = LoupeRaster(render: { request in await gate.render(request) })
        func rasterRequest(_ x: CGFloat) -> LoupeRasterRequest {
            LoupeRasterRequest(scene: LoupeSceneInput(photos: [photo(enlarged)], point: CGPoint(x: x, y: 300),
                panelBounds: nil, transmission: 1, flare: 0, brightness: 1), diameter: 810, displayScale: 1)
        }
        func waitForCalls(_ count: Int) async {
            for _ in 0..<200 {
                if await gate.count >= count { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("raster worker did not receive expected request")
        }
        raster.request(rasterRequest(10))
        await waitForCalls(1)
        check(raster.image == nil, "request returns before background rendering finishes")
        for x in 11...100 { raster.request(rasterRequest(CGFloat(x))) }
        await gate.finish(image)
        await waitForCalls(2)
        let initialCalls = await gate.requests
        check(initialCalls.count == 2 && initialCalls[0].diameter == 260 && initialCalls[1].scene.point.x == 100,
              "ninety pointer events collapse to latest position after quick first frame")
        await gate.finish(close)
        for _ in 0..<200 {
            if raster.image === close { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        check(raster.image === close, "latest view replaces quick frame at final resolution")
        raster.request(rasterRequest(100))
        try await Task.sleep(for: .milliseconds(5))
        let idleCalls = await gate.count
        check(idleCalls == 2, "unchanged scene and animation progress do not trigger another render")
        raster.request(rasterRequest(200))
        await waitForCalls(3)
        raster.cancel()
        await gate.finish(image)
        try await Task.sleep(for: .milliseconds(5))
        check(raster.image == nil, "cancelled in-flight render cannot repopulate a dismissed lens")
        let actualRaster = LoupeRaster()
        actualRaster.request(rasterRequest(samplePoint.x))
        for _ in 0..<1000 {
            if actualRaster.image?.width == 810 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        check(actualRaster.image?.width == 810, "production worker delivers final-resolution image asynchronously")
        actualRaster.cancel()
        let ordinaryGate = RasterGate()
        let ordinaryRaster = LoupeRaster(render: { request in await ordinaryGate.render(request) })
        let ordinaryRequest = LoupeRasterRequest(scene: rasterRequest(samplePoint.x).scene,
            diameter: LoupeGeometry.rasterDiameter(in: CGSize(width: 2200, height: 1100), closeViewing: false),
            displayScale: 2)
        ordinaryRaster.request(ordinaryRequest)
        for _ in 0..<200 {
            if await ordinaryGate.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let ordinaryCalls = await ordinaryGate.requests
        check(ordinaryCalls.count == 1 && ordinaryCalls[0].diameter == 260 && ordinaryCalls[0].displayScale == 2,
              "ordinary rendering retains Retina detail without a close-view-sized allocation")
        await ordinaryGate.finish(image)
        for _ in 0..<200 {
            if ordinaryRaster.image === image { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        try? await Task.sleep(for: .milliseconds(5))
        let ordinaryCount = await ordinaryGate.count
        check(ordinaryCount == 1 && ordinaryRaster.image === image,
              "ordinary movement never schedules an unnecessary high-resolution second pass")
        ordinaryRaster.cancel()

        var received: [UUID: SlidePlacement] = [:]
        let probe = NSHostingView(rootView: PreferenceProbe(placement: baseline, id: slide.id) { received = $0 })
        probe.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        probe.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(25))
        probe.rootView = PreferenceProbe(placement: rotated, id: slide.id) { received = $0 }
        probe.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(25))
        check(received[slide.id] == rotated, "SwiftUI geometry preference publishes live pinch and rotation")

        let state = LoupeExperience()
        check(state.closeMagnification == .original, "original close magnification remains the default")
        state.closeMagnification = .eight
        let scene = LoupeSceneInput(photos: [photo(enlarged)], point: point,
                                   panelBounds: CGRect(origin: .zero, size: board), transmission: 1, flare: 0, brightness: 1)
        state.pointer = point
        check(!state.press(), "space without a visible lens does not start a close view")
        state.scene = scene
        check(state.press() && state.isClose && state.cursorHidden, "space down enters and hides cursor")
        let movedPoint = CGPoint(x: 800, y: 500)
        state.pointer = movedPoint
        check(state.sourcePoint == movedPoint, "held-space view follows pointer movement instead of locking the source")
        state.pointer = nil
        check(state.sourcePoint == movedPoint, "leaving the canvas retains the latest viewed point")
        state.pointer = movedPoint
        state.release(reduceMotion: false)
        check(!state.isClose && state.anchor == movedPoint, "release returns at the latest viewed point")
        let returnPoint = CGPoint(x: 760, y: 480)
        state.pointer = returnPoint
        check(state.sourcePoint == returnPoint, "pointer remains responsive while the close view returns")
        try await Task.sleep(for: .milliseconds(35))
        check(state.press() && state.anchor == returnPoint, "repress reverses return without jumping to another source point")
        try await Task.sleep(for: .seconds(LoupeGeometry.exitDuration + 0.05))
        check(state.isClose && state.anchor == returnPoint, "cancelled return cannot interrupt a new close view")
        state.release(reduceMotion: true)
        check(state.anchor == nil && !state.cursorHidden && !state.isClose, "reduced motion exits immediately and restores cursor")
        _ = state.press(); state.release(reduceMotion: false)
        check(state.anchor != nil && state.cursorHidden, "return retains its high-resolution scene until the motion finishes")
        try await Task.sleep(for: .seconds(LoupeGeometry.exitDuration + 0.05))
        check(state.anchor == nil && !state.cursorHidden, "normal return completes and restores the pointer after the new duration")
        _ = state.press(); state.cancel()
        check(state.anchor == nil && !state.cursorHidden && !state.isClose, "cancellation balances cursor and clears close state")
        check(state.closeMagnification == .eight, "pointer mode and cancellation retain the selected close magnification")

        let tracking = LoupeExperience()
        tracking.scene = scene; tracking.pointer = point
        tracking.pointer = CGPoint(x: 420, y: 320)
        check(tracking.sourcePoint == tracking.pointer, "ordinary lens tracks the pointer directly")
        _ = tracking.press()
        tracking.pointer = CGPoint(x: 440, y: 340)
        check(tracking.sourcePoint == tracking.pointer, "approaching lens retains ordinary movement speed")
        try await Task.sleep(for: .seconds(LoupeGeometry.enterDuration + 0.03))
        tracking.pointer = CGPoint(x: 540, y: 380)
        check(tracking.sourcePoint == tracking.pointer, "fully approached lens keeps full movement on both axes")
        _ = tracking.press()
        tracking.pointer = CGPoint(x: 520, y: 360)
        check(tracking.sourcePoint == tracking.pointer, "held space and direction reversal preserve direct tracking")
        let outside = tracking.sourcePoint
        tracking.pointer = nil
        check(tracking.sourcePoint == outside, "hover exit retains the last inspected point")
        tracking.pointer = CGPoint(x: 700, y: 400)
        check(tracking.sourcePoint == tracking.pointer, "hover re-entry resumes at the real pointer without a stored offset")
        tracking.release(reduceMotion: false)
        tracking.pointer = CGPoint(x: 720, y: 420)
        check(tracking.sourcePoint == tracking.pointer, "return retains the same movement speed without offset recovery")
        _ = tracking.press()
        tracking.pointer = CGPoint(x: 740, y: 440)
        check(tracking.sourcePoint == tracking.pointer, "repress during return preserves unified movement speed")
        tracking.release(reduceMotion: true)
        tracking.pointer = CGPoint(x: 500, y: 400)
        check(tracking.sourcePoint == tracking.pointer && !tracking.cursorHidden,
              "reduced-motion return restores the cursor and retains direct tracking")
        tracking.cancel()

        // Verify the actual view scales pixels inside a stationary circle,
        // rather than merely satisfying the independent timing equations.
        let targetContext = CGContext(data: nil, width: 260, height: 260, bitsPerComponent: 8, bytesPerRow: 1040,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        targetContext.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        targetContext.fill(CGRect(x: 0, y: 0, width: 156, height: 260))
        targetContext.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        targetContext.fill(CGRect(x: 156, y: 0, width: 104, height: 260))
        let targetImage = targetContext.makeImage()!
        func sampleOptic(_ scale: CGFloat, x: CGFloat, y: CGFloat) -> NSColor {
            let view = NSHostingView(rootView: OpticalLoupe(image: targetImage, transmission: 1, contentScale: scale)
                .frame(width: 260, height: 260))
            view.frame = CGRect(x: 0, y: 0, width: 260, height: 260)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / 260),
                                  y: Int(y * CGFloat(bitmap.pixelsHigh) / 260))!.usingColorSpace(.sRGB)!
        }
        let still = sampleOptic(1, x: 168, y: 130), approaching = sampleOptic(2, x: 168, y: 130)
        check(still.blueComponent > 0.7 && approaching.redComponent > 0.7,
              "production optic visibly advances the photograph within the unchanged circle")
        check(sampleOptic(2, x: 5, y: 5).alphaComponent < 0.01,
              "enlarged photograph remains clipped inside the circular glass")

        let blackContext = CGContext(data: nil, width: 260, height: 260, bitsPerComponent: 8, bytesPerRow: 1040,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        blackContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        blackContext.fill(CGRect(x: 0, y: 0, width: 260, height: 260))
        // All variants share source dimensions, as they do in the production preview pipeline.
        let comparisonContext = CGContext(data: nil, width: 260, height: 260, bitsPerComponent: 8, bytesPerRow: 1040,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        comparisonContext.setFillColor(CGColor(red: 0.9, green: 0.05, blue: 0.05, alpha: 1))
        comparisonContext.fill(CGRect(x: 0, y: 0, width: 130, height: 260))
        comparisonContext.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.9, alpha: 1))
        comparisonContext.fill(CGRect(x: 130, y: 0, width: 130, height: 260))
        let comparisonSource = comparisonContext.makeImage()!
        let comparison = PhotoPreview(source: comparisonSource, lit: targetImage, dark: comparisonSource, flare: blackContext.makeImage()!,
                                      boosted: targetImage)
        func comparisonPixel(_ image: CGImage, x: Int, y: Int) -> NSColor {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            let index = (y * image.width + x) * 4
            return NSColor(srgbRed: CGFloat(bytes[index]) / 255, green: CGFloat(bytes[index + 1]) / 255,
                blue: CGFloat(bytes[index + 2]) / 255, alpha: CGFloat(bytes[index + 3]) / 255)
        }
        func tablePixel(_ textured: Bool, transmission: Double = 1) -> NSColor {
            let view = NSHostingView(rootView: TransmittedPhoto(preview: comparison.viewing(transmitted: textured),
                size: CGSize(width: 260, height: 260), transmission: transmission, flare: 0, brightness: 1, usesMetal: false))
            view.frame = CGRect(x: 0, y: 0, width: 260, height: 260)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return comparisonPixel(bitmap.cgImage!, x: bitmap.pixelsWide * 55 / 100, y: bitmap.pixelsHigh / 2)
        }
        let tableOriginal = tablePixel(false), tableTexture = tablePixel(true)
        check(tableOriginal.blueComponent > 0.7 && tableTexture.redComponent > 0.7,
              "shared photo view switches from original pixels to the cached transmitted pixels")
        for textured in [false, true] {
            let lens = LoupeRenderer.shared.render(preview: comparison.viewing(transmitted: textured),
                point: CGPoint(x: 143, y: 130), imageSize: CGSize(width: 260, height: 260),
                diameter: 260, magnification: 1.5, displayScale: 1,
                transmission: 1, flare: 0, brightness: 1, refracts: false)!
            let a = comparisonPixel(lens, x: lens.width / 2, y: lens.height / 2), b = tablePixel(textured)
            check(abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02,
                  "lens and table share comparison colors with transmission \(textured): lens=\(a), table=\(b)")
        }
        let darkOriginal = tablePixel(false, transmission: 0), darkTexture = tablePixel(true, transmission: 0)
        check(abs(darkOriginal.redComponent - darkTexture.redComponent) < 0.01 &&
              abs(darkOriginal.blueComponent - darkTexture.blueComponent) < 0.01,
              "appearance switch leaves the unlit film unchanged")
        func comparisonScene(_ textured: Bool) -> LoupeSceneInput {
            LoupeSceneInput(photos: [LoupeScenePhoto(preview: comparison.viewing(transmitted: textured),
                center: CGPoint(x: 130, y: 130), imageSize: CGSize(width: 260, height: 260))],
                point: CGPoint(x: 143, y: 130), panelBounds: nil, transmission: 1, flare: 0, brightness: 1)
        }
        check(comparisonScene(false) != comparisonScene(true) && comparisonScene(true) == comparisonScene(true),
              "comparison invalidates the lens once while unchanged cached mode stays equal")

        let leftGlass = LoupeGlassPose(origin: CGPoint(x: 80, y: 200), size: board, progress: 0, reduceMotion: false)
        let rightGlass = LoupeGlassPose(origin: CGPoint(x: 920, y: 500), size: board, progress: 0, reduceMotion: false)
        check(leftGlass.angle < rightGlass.angle && abs(leftGlass.angle) < 22 && abs(rightGlass.angle) < 22,
              "glass reflection changes gently with viewing position")
        let reducedA = LoupeGlassPose(origin: CGPoint(x: 0, y: 0), size: board, progress: 0, reduceMotion: true)
        let reducedB = LoupeGlassPose(origin: CGPoint(x: 900, y: 700), size: board, progress: 0, reduceMotion: true)
        check(reducedA == reducedB, "reduced motion holds glass reflections still")
        let closeGlass = LoupeGlassPose(origin: CGPoint(x: 80, y: 200), size: board, progress: 1, reduceMotion: false)
        check(closeGlass.intensity == 0 && leftGlass.intensity == 1,
              "restrained glass reflections fade without increasing the field magnification")
        let invalidGlass = LoupeGlassPose(origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), size: .zero,
                                          progress: CGFloat.nan, reduceMotion: false)
        check(invalidGlass.angle.isFinite && invalidGlass.intensity.isFinite,
              "invalid viewing geometry cannot leak into glass rendering")
        func glassBitmap(_ pose: LoupeGlassPose) -> CGImage {
            let view = NSHostingView(rootView: LoupeGlassSurface(pose: pose, transmission: 1)
                .frame(width: 260, height: 260))
            view.frame = CGRect(x: 0, y: 0, width: 260, height: 260)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap.cgImage!
        }
        let glassLeft = glassBitmap(leftGlass), glassRight = glassBitmap(rightGlass), glassClose = glassBitmap(closeGlass)
        let leftRep = NSBitmapImageRep(cgImage: glassLeft), rightRep = NSBitmapImageRep(cgImage: glassRight)
        let closeRep = NSBitmapImageRep(cgImage: glassClose)
        var centreAlpha: CGFloat = 0, reflectionChange: CGFloat = 0, edgeAlpha: CGFloat = 0
        var closeEdgeAlpha: CGFloat = 0, darkBevel: CGFloat = 0, brightLip: CGFloat = 0
        for y in stride(from: 0, to: glassLeft.height, by: 3) {
            for x in stride(from: 0, to: glassLeft.width, by: 3) {
                let radius = hypot(CGFloat(x) / CGFloat(glassLeft.width) - 0.5,
                                   CGFloat(y) / CGFloat(glassLeft.height) - 0.5) * 2
                let color = leftRep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let a = color.alphaComponent
                let b = rightRep.colorAt(x: x, y: y)!.alphaComponent
                let c = closeRep.colorAt(x: x, y: y)!.alphaComponent
                if radius < 0.90 { centreAlpha = max(centreAlpha, max(a, max(b, c))) }
                if radius > 0.95 && radius < 0.999 {
                    edgeAlpha = max(edgeAlpha, max(a, b))
                    closeEdgeAlpha = max(closeEdgeAlpha, c)
                    reflectionChange = max(reflectionChange, abs(a - b))
                }
                let white = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if radius > 0.978 && radius < 0.992 { darkBevel = max(darkBevel, a * (1 - white)) }
                if radius > 0.992 && radius < 0.999 { brightLip = max(brightLip, a * white) }
            }
        }
        check(centreAlpha < 0.01, "glass surface leaves the central photograph fully clear")
        check(edgeAlpha > 0.03 && edgeAlpha < 0.30 && reflectionChange > 0.005,
              "production glass draws visible rim reflections that move relative to the photograph")
        check(closeEdgeAlpha < 0.01,
              "production glass removes the rim reflection when fully immersed")
        check(darkBevel > 0.02 && darkBevel < 0.16 && brightLip > 0.03 && brightLip < 0.30,
              "production glass keeps a narrow, restrained dark bevel and bright lip")

        let corner = CGPoint(x: 110, y: 120)
        let windowSize = CGSize(width: 840, height: 640)
        let adjusted = LoupeGeometry.closeCenter(from: corner, in: windowSize)
        check(adjusted.x < 420 && adjusted.y < 320,
              "rollback keeps an edge lens near its inspected side instead of recentering")
        for edge in [CGPoint(x: 0, y: 0), CGPoint(x: 840, y: 0), CGPoint(x: 0, y: 640), CGPoint(x: 840, y: 640),
                     CGPoint(x: 420, y: 0), CGPoint(x: 420, y: 640), CGPoint(x: 0, y: 320), CGPoint(x: 840, y: 320)] {
            let center = LoupeGeometry.closeCenter(from: edge, in: windowSize)
            let radius = LoupeGeometry.closeDiameter(in: windowSize) / 2 + 6
            check(center.x >= radius && center.x + radius <= 840 && center.y >= radius && center.y + radius <= 640,
                  "rollback keeps the complete lens inside the window at \(edge)")
        }
        check(LoupeGeometry.closeCenter(from: CGPoint(x: 400, y: 320), in: windowSize) == CGPoint(x: 400, y: 320),
              "interior lens retains its original position")

        let frame = NSRect(x: -2000, y: -2000, width: 120, height: 100)
        let window = KeyWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let monitor = LoupeKeyboard.MonitorView(frame: frame)
        window.contentView = monitor
        window.alphaValue = 0; window.orderFront(nil)
        defer { monitor.stop(); window.orderOut(nil); state.cancel() }
        var presses = 0, releases = 0, cancellations = 0
        monitor.enabled = true
        monitor.pressed = { presses += 1; return true }
        monitor.released = { releases += 1 }
        monitor.cancelled = { cancellations += 1 }
        func key(_ type: NSEvent.EventType, repeat repeated: Bool = false,
                 modifiers: NSEvent.ModifierFlags = [], number: Int? = nil, code: UInt16 = 49) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: number ?? window.windowNumber, context: nil, characters: code == 48 ? "\t" : " ",
                charactersIgnoringModifiers: code == 48 ? "\t" : " ", isARepeat: repeated, keyCode: code)!
        }
        check(monitor.handle(key(.keyDown)) == nil && monitor.handle(key(.keyDown, repeat: true)) == nil && presses == 1,
              "keyboard consumes held space without autorepeat reentry or beep")
        check(monitor.handle(key(.keyUp, modifiers: .shift)) == nil && releases == 1,
              "space up exits even if modifiers changed during hold")
        check(monitor.handle(key(.keyDown, modifiers: .command)) != nil && presses == 1,
              "command-space passes through unchanged")
        let text = NSTextView(frame: .zero)
        monitor.addSubview(text)
        window.makeFirstResponder(text)
        check(monitor.handle(key(.keyDown)) != nil && presses == 1, "text input retains its space key")
        window.makeFirstResponder(monitor)
        check(monitor.handle(key(.keyDown, number: 0)) != nil && presses == 1, "other-window keys do not trigger this lens")
        _ = monitor.handle(key(.keyDown))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(cancellations > 0 && monitor.handle(key(.keyUp)) != nil,
              "window focus loss clears held-space state")
        monitor.enabled = false
        check(monitor.handle(key(.keyDown)) != nil && presses == 2, "pointer mode leaves space unhandled")

        var cycles = 0
        state.closeMagnification = .original
        monitor.cycleMagnification = { cycles += 1; state.cycleMagnification() }
        check(monitor.handle(key(.keyDown, code: 48)) != nil && cycles == 0,
              "pointer mode leaves Tab for normal focus navigation")
        monitor.enabled = true
        check(monitor.handle(key(.keyDown, code: 48)) == nil && cycles == 1 && state.closeMagnification == .eight,
              "Tab selects 8x while the ordinary lens is active")
        check(monitor.handle(key(.keyDown, repeat: true, code: 48)) == nil && cycles == 1,
              "holding Tab does not repeatedly cycle magnifications")
        check(monitor.handle(key(.keyUp, modifiers: .shift, code: 48)) == nil,
              "Tab release is consumed even when modifiers change during the hold")
        check(monitor.handle(key(.keyDown, code: 48)) == nil && cycles == 2 && state.closeMagnification == .original,
              "a second Tab press returns to the original magnification")
        _ = monitor.handle(key(.keyUp, code: 48))
        monitor.pressed = { state.press() }
        monitor.released = { state.release(reduceMotion: true) }
        monitor.cancelled = { cancellations += 1; state.cancel() }
        _ = monitor.handle(key(.keyDown))
        let heldPoint = state.sourcePoint
        check(monitor.handle(key(.keyDown, code: 48)) == nil && state.closeMagnification == .eight &&
              state.isClose && state.cursorHidden && state.sourcePoint == heldPoint,
              "Tab changes magnification during held-space viewing without dropping the lens or source point")
        _ = monitor.handle(key(.keyUp, code: 48))
        check(monitor.handle(key(.keyUp)) == nil && !state.isClose && !state.cursorHidden,
              "space release still returns normally after a Tab magnification change")
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            check(monitor.handle(key(.keyDown, modifiers: modifiers, code: 48)) != nil && cycles == 3,
                  "modified Tab passes through: \(modifiers.rawValue)")
        }
        window.makeFirstResponder(text)
        check(monitor.handle(key(.keyDown, code: 48)) != nil && cycles == 3,
              "text input retains Tab navigation")
        window.makeFirstResponder(monitor)
        check(monitor.handle(key(.keyDown, number: 0, code: 48)) != nil && cycles == 3,
              "Tab from another window does not change magnification")
        check(monitor.handle(key(.keyDown, repeat: true, code: 48)) != nil && cycles == 3,
              "a stray Tab repeat without a captured press does not change magnification")
        _ = monitor.handle(key(.keyDown, code: 48))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(monitor.handle(key(.keyUp, code: 48)) != nil &&
              monitor.handle(key(.keyDown, code: 48)) == nil && cycles == 5,
              "focus loss clears Tab state so the next press can switch again")
        monitor.enabled = false
        monitor.reset()
        check(monitor.handle(key(.keyUp, code: 48)) != nil &&
              monitor.handle(key(.keyDown, code: 48)) != nil && cycles == 5,
              "leaving loupe mode clears Tab capture and restores normal navigation")
        monitor.stop()
        check(cancellations > 1, "view teardown cancels input state and removes monitor")

        window.setContentSize(CGSize(width: 500, height: 400))
        let selectionMonitor = CanvasSelection.MonitorView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = selectionMonitor
        selectionMonitor.enabled = true
        var selectionStarts = 0, selectionEnds = 0, selectionCancels = 0
        var lastMarquee: CGRect?
        selectionMonitor.began = { selectionStarts += 1 }
        selectionMonitor.changed = { lastMarquee = $0 }
        selectionMonitor.ended = { selectionEnds += 1 }
        selectionMonitor.cancelled = { selectionCancels += 1 }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = .shift, number: Int? = nil) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: selectionMonitor.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: 0, windowNumber: number ?? window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 100, y: 100), modifiers: [])) != nil,
              "ordinary mouse drags pass through to photo movement and board panning")
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 100, y: 100), modifiers: .command)) != nil,
              "command-click remains available for multi-selection")
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 100, y: 35))) != nil,
              "Shift input on the toolbar is not captured as a marquee")
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 100, y: 100), number: 0)) != nil,
              "mouse input from another window never starts a marquee")
        selectionMonitor.excludedRect = CGRect(x: 280, y: 240, width: 100, height: 80)
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 300, y: 260))) != nil && selectionStarts == 0,
              "guide card does not start a marquee underneath")
        selectionMonitor.excludedRect = nil
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 300, y: 260))) == nil && selectionStarts == 1,
              "Shift press starts a captured marquee before photo drag gestures")
        check(selectionMonitor.handle(mouse(.leftMouseDragged, CGPoint(x: 100, y: 90), modifiers: [])) == nil &&
              lastMarquee == CGRect(x: 100, y: 90, width: 200, height: 170),
              "reverse dragging keeps the captured selection even if Shift is released")
        check(selectionMonitor.handle(mouse(.leftMouseUp, CGPoint(x: 600, y: 0), modifiers: [])) == nil && selectionEnds == 1 &&
              lastMarquee == CGRect(x: 300, y: 64, width: 200, height: 196),
              "marquee clamps to the board and completes without leaking a mouse-up")
        _ = selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 120, y: 150)))
        check(selectionMonitor.handle(key(.keyDown, code: 53)) == nil && selectionCancels == 1,
              "Escape cancels a marquee so the previous selection can be restored")
        check(selectionMonitor.handle(mouse(.leftMouseUp, CGPoint(x: 150, y: 170))) == nil && selectionEnds == 1,
              "cancelled marquee consumes its release without committing selection")
        _ = selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 120, y: 150)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(selectionCancels == 2, "focus loss cancels selection and balances the crosshair cursor")
        selectionMonitor.enabled = false
        check(selectionMonitor.handle(mouse(.leftMouseDown, CGPoint(x: 120, y: 150))) != nil,
              "disabled marquee leaves loupe and slideshow interactions unchanged")
        selectionMonitor.stop()
        print("RESULT \(count) passed; 0 failed")
    }
}
