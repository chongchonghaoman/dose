import AppKit
import CoreImage
import MetalKit
import LightTableCore

@main struct OpticsChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ yes: Bool, _ message: String) {
            precondition(yes, message); count += 1; print("PASS \(message)")
        }
        let context = CIContext(options: [.workingColorSpace: PhotoOptics.blendSpace, .cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        func image(_ r: CGFloat, _ g: CGFloat? = nil, _ b: CGFloat? = nil) -> CGImage {
            let color = CIImage(color: CIColor(red: r, green: g ?? r, blue: b ?? r, colorSpace: PhotoOptics.linearSpace)!)
            return context.createCGImage(color, from: bounds, format: .RGBAh, colorSpace: PhotoOptics.linearSpace)!
        }
        func pixel(_ input: CIImage, x: CGFloat = 32, y: CGFloat = 32) -> [Float] {
            var values = [Float](repeating: 0, count: 4)
            values.withUnsafeMutableBytes {
                context.render(input, toBitmap: $0.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                    colorSpace: PhotoOptics.linearSpace)
            }
            return values
        }
        func lit(_ source: CGImage, transmitted: Bool = true, t: Double = 1) -> CIImage {
            let p = PhotoPreview(source: source, lit: source, dark: image(0.01), flare: image(0))
                .viewing(transmitted: transmitted)
            return PhotoOptics.composite(preview: p, transmission: t, flare: 0, brightness: 1)
        }
        check(PhotoOptics.fusedOpticalKernel != nil, "SDR lamp and ignition kernel compiles")
        check(PhotoOptics.ignitionKernel != nil, "ignition exposure kernel compiles")
        func exposed(_ source: CGImage, time: Double, brightness: Double = 1) -> CIImage {
            let p = PhotoPreview(source: source, lit: source, dark: image(0.001), flare: image(0))
            let response = LightResponse.sample(elapsed: time, isLit: true)
            return PhotoOptics.composite(preview: p, transmission: response.transmission, flare: response.flare,
                                         brightness: brightness)
        }
        let middle = image(0.18), brightScene = image(0.65)
        let peakMiddle = pixel(exposed(middle, time: 0.16))[0]
        check(peakMiddle > 0.26 && peakMiddle < 0.29, "ignition has a visible, bounded exposure peak")
        check(pixel(exposed(brightScene, time: 0.16))[0] > 0.88 && pixel(exposed(brightScene, time: 0.16))[0] < 0.96, "ignition retains moderately bright scene detail")
        check(abs(pixel(exposed(middle, time: 0.28))[0] - peakMiddle) < 0.001, "overexposure holds before recovery")
        var lastExposure = peakMiddle
        for step in 0...24 {
            let value = pixel(exposed(middle, time: 0.28 + Double(step) * 0.82 / 24))[0]
            check(value <= lastExposure + 0.001 && value >= 0.179, "recovery is monotonic without undershoot at step \(step)")
            lastExposure = value
        }
        check(abs(lastExposure - 0.18) < 0.002, "recovery restores the original steady exposure exactly")
        check(abs(pixel(exposed(middle, time: 1.10))[0] - 0.18) < 0.002, "exposure is fully restored at 1.10 seconds")
        check(pixel(exposed(image(0), time: 0.16))[0] < 0.001 &&
              pixel(exposed(image(0.002), time: 0.16))[0] < 0.003, "ignition preserves opaque black film")
        check(pixel(exposed(middle, time: 0.16, brightness: 0.1))[0] < peakMiddle, "dim lamp also limits ignition exposure")
        var lastHighlight: Float = 0
        for tone: CGFloat in [0.55, 0.65, 0.75, 0.85, 0.94, 0.98, 1] {
            let value = pixel(exposed(image(tone), time: 0.16))[0]
            check(value > lastHighlight && value <= 1.002 && value + 0.002 >= Float(tone),
                  "ignition shoulder preserves highlight separation at tone \(tone)")
            lastHighlight = value
        }
        let ignitionColor = image(0.85, 0.30, 0.09)
        let ignitionBase = pixel(CIImage(cgImage: ignitionColor))
        let ignitionPeak = pixel(exposed(ignitionColor, time: 0.16))
        check(abs(ignitionBase[1] / ignitionBase[0] - ignitionPeak[1] / ignitionPeak[0]) < 0.003 &&
              abs(ignitionBase[2] / ignitionBase[0] - ignitionPeak[2] / ignitionPeak[0]) < 0.003,
              "ignition shoulder retains saturated highlight hue")
        for power in [0.1, 1, 1.6] {
            for flare in [0.0, 0.25, 0.6, 1] {
                let input = CIImage(cgImage: ignitionColor)
                let separate = PhotoOptics.ignition(PhotoOptics.lamp(input, brightness: power), flare: flare, brightness: power)
                let fused = PhotoOptics.fusedOptical(input, lampBrightness: power,
                    exposureStops: LightResponse.photoExposureStops(flare: flare, brightness: power))
                check(zip(pixel(separate), pixel(fused)).allSatisfy { abs($0 - $1) < 0.003 },
                      "standalone and fused ignition agree at power \(power), flare \(flare)")
            }
        }
        for value: CGFloat in [0, 0.02, 0.18, 0.35, 0.47, 0.65, 0.94, 1] {
            let source = image(value)
            check(abs(pixel(lit(source))[0] - Float(value)) < 0.002,
                  "ordinary display preserves source tone \(value) at default brightness")
        }
        check(PhotoOptics.lampKernel != nil, "linear transmission kernel compiles")
        func powered(_ source: CGImage, _ brightness: Double) -> [Float] {
            let p = PhotoPreview(source: source, lit: source, dark: image(0.001), flare: image(0))
            return pixel(PhotoOptics.composite(preview: p, transmission: 1, flare: 0, brightness: brightness))
        }
        for tone: CGFloat in [0, 0.002, 0.02, 0.08, 0.18, 0.35] {
            let low = powered(image(tone), 1)[0], high = powered(image(tone), 1.6)[0]
            check(abs(high - low * 1.6) < 0.002, "linear power scales 1.6x at tone \(tone)")
        }
        for tone: CGFloat in [0.18, 0.65, 0.85, 0.95, 1] {
            var previous = powered(image(tone), 1)[0]
            for step in 101...160 {
                let value = powered(image(tone), Double(step) / 100)[0]
                precondition(value + 0.002 >= previous && value <= 1.002, "slider dims or exceeds ordinary white")
                previous = value
            }
        }
        check(true, "brightness slider remains monotonic within ordinary white")
        var previous: Float = 0
        for tone: CGFloat in [0.65, 0.8, 0.9, 0.94, 0.98, 1] {
            let value = powered(image(tone), 1.6)[0]
            precondition(value > previous, "high lamp merges highlight steps")
            previous = value
        }
        check(true, "high lamp preserves highlight steps without EDR")
        let lampColor = image(0.6, 0.2, 0.08)
        let lampNormal = powered(lampColor, 1), lampStrong = powered(lampColor, 1.6)
        check(abs(lampNormal[1] / lampNormal[0] - lampStrong[1] / lampStrong[0]) < 0.003 &&
              abs(lampNormal[2] / lampNormal[0] - lampStrong[2] / lampStrong[0]) < 0.003, "strong lamp preserves linear color ratios")
        let lampPreview = PhotoPreview(source: middle, lit: middle, dark: image(0.001), flare: image(0))
        let strongLens = LoupeRenderer.shared.render(photos: [LoupeScenePhoto(preview: lampPreview,
            center: CGPoint(x: 32, y: 32), imageSize: CGSize(width: 64, height: 64))], point: CGPoint(x: 32, y: 32),
            diameter: 32, magnification: 1.5, displayScale: 1, transmission: 1, flare: 0, brightness: 1.6,
            refracts: false)!
        check(abs(pixel(CIImage(cgImage: strongLens), x: 16, y: 16)[0] - powered(middle, 1.6)[0]) < 0.005,
              "lens and table agree at 160 percent power")
        let warm = image(0.95, 0.46, 0.12)
        let sdr = pixel(lit(warm)), raw = pixel(CIImage(cgImage: warm))
        check(zip(sdr, raw).allSatisfy { abs($0 - $1) < 0.002 }, "SDR preserves the complete source color")
        let original = pixel(lit(warm, transmitted: false))
        check(zip(sdr, original).allSatisfy { abs($0 - $1) < 0.002 }, "original and transmitted default tones agree")
        check(pixel(lit(warm, t: 0))[0] < 0.02, "unlit film remains dark")
        let source = image(0.94)
        let preview = PhotoPreview(source:source,lit:source,dark:image(0.01),flare:image(0))
        let lens = LoupeRenderer.shared.render(photos:[LoupeScenePhoto(preview:preview,
            center:CGPoint(x:32,y:32),imageSize:CGSize(width:64,height:64))], point:CGPoint(x:32,y:32),
            diameter:32,magnification:1.5,displayScale:1,transmission:1,flare:0,brightness:1,
            refracts:false)!
        check(lens.bitsPerComponent == 8 && !lens.bitmapInfo.contains(.floatComponents), "lens exports ordinary 8-bit P3")
        check(abs(pixel(CIImage(cgImage:lens),x:16,y:16)[0]-pixel(lit(source))[0])<0.005,
              "lens and table share the same actual light output")
        let ignitionPreview = PhotoPreview(source: middle, lit: middle, dark: image(0.001), flare: image(0))
        let ignitionLens = LoupeRenderer.shared.render(photos: [LoupeScenePhoto(preview: ignitionPreview,
            center: CGPoint(x: 32, y: 32), imageSize: CGSize(width: 64, height: 64))],
            point: CGPoint(x: 32, y: 32), diameter: 32, magnification: 1.5, displayScale: 1,
            transmission: 1, flare: 1, brightness: 1, refracts: false)!
        let tableIgnition = PhotoOptics.composite(preview: ignitionPreview, transmission: 1, flare: 1, brightness: 1)
        check(abs(pixel(CIImage(cgImage: ignitionLens), x: 16, y: 16)[0] - pixel(tableIgnition)[0]) < 0.005,
              "lens and tabletop use identical ignition exposure")
        for power in [0.1, 1, 1.6] {
            var previousPanel: Float = 2
            for time in [0.16, 0.28, 0.45, 0.80, 1.10] {
                let response = LightResponse.sample(elapsed: time, isLit: true)
                let panel = LoupeRenderer.shared.composite(photos: [], point: .zero,
                    diameter: 32, magnification: 1.5, displayScale: 1,
                    transmission: response.transmission, flare: response.flare, brightness: power, refracts: false)!
                let white = CGFloat(LightResponse.panelWhite(brightness: power, flare: response.flare))
                let tablePanel = CIImage(color: CIColor(red: white, green: white, blue: white))
                let value = pixel(panel, x: 16, y: 16)[0]
                check(abs(value - pixel(tablePanel)[0]) < 0.002 && value <= previousPanel + 0.002,
                      "lens panel matches table during recovery at power \(power), time \(time)")
                previousPanel = value
            }
        }
        check(LightResponse.photoExposureStops(flare: 0, brightness: 1) == 0 &&
              LightResponse.photoExposureStops(flare: .nan, brightness: 1) == 0,
              "settled and invalid ignition levels add no exposure")
        if let gpu = OpticalMetalView.gpu, let queue = gpu.makeCommandQueue() {
            let view = OpticalMetalView()
            check(view.colorPixelFormat == .bgra8Unorm && view.isPaused && view.enableSetNeedsDisplay,
                  "production display uses 8-bit output without idle rendering")
            check((view.layer as? CAMetalLayer)?.presentsWithTransaction == true,
                  "photograph surfaces present with one Core Animation transaction")
            for transmission in [0.0, 0.5, 1.0] {
                view.set(preview: preview, image: nil, transmission: transmission, flare: 0, brightness: 1)
                check((view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent == false,
                      "surface never requests extra screen brightness at transmission \(transmission)")
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .shared
            let renderer = CIContext(mtlDevice: gpu, options: [.workingColorSpace: PhotoOptics.blendSpace])
            func renderSurface(_ surface: OpticalMetalView) async throws -> [UInt8] {
                let texture = gpu.makeTexture(descriptor: descriptor)!, buffer = queue.makeCommandBuffer()!
                precondition(surface.encode(into: texture, commandBuffer: buffer, renderer: renderer), "production surface failed to encode")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    buffer.addCompletedHandler { _ in continuation.resume() }
                    buffer.commit()
                }
                // Flush the completion callback that publishes a valid cache on the main queue.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                precondition(buffer.status == .completed, "GPU rejected production surface encoding")
                var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
                bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 64 * 4,
                    from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0) }
                return bytes
            }
            let split = context.createCGImage(
                CIImage(color: CIColor(red: 0.8, green: 0.02, blue: 0.02)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
                    .composited(over: CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.8)).cropped(to: bounds)),
                from: bounds)!
            let splitPreview = PhotoPreview(source: split, lit: split, dark: image(0), flare: image(0))
            func liveInput(_ x: CGFloat, diameter: CGFloat, width: CGFloat = 64, brightness: Double = 1) -> LoupeDisplayInput {
                LoupeDisplayInput(scene: LoupeSceneInput(photos: [LoupeScenePhoto(preview: splitPreview,
                    center: CGPoint(x: 32, y: 32), imageSize: CGSize(width: width, height: 64))],
                    point: CGPoint(x: x, y: 32), panelBounds: nil, transmission: 1, flare: 0, brightness: brightness),
                    diameter: diameter, magnification: 1.5 * diameter / 260, displayScale: 2)
            }
            func setLive(_ input: LoupeDisplayInput) {
                view.set(preview: nil, image: nil, transmission: 1, flare: 0, brightness: 1, loupe: input)
            }
            for diameter: CGFloat in [260, 810] {
                for x: CGFloat in [16, 48, 16] {
                    let live = liveInput(x, diameter: diameter)
                    setLive(live)
                    let composed = view.composedInput()!
                    let value = pixel(composed, x: live.pixelSize.width / 2, y: live.pixelSize.height / 2)
                    check(x < 32 ? value[0] > value[2] * 5 : value[2] > value[0] * 5,
                          "live lens samples the current point on direction reversal at diameter \(diameter), x \(x)")
                    check(!view.autoResizeDrawable && view.drawableSize == live.pixelSize && composed.extent.size == live.pixelSize,
                          "live lens preserves final Retina drawable resolution at diameter \(diameter)")
                }
                // Several pointer events before encoding: only the last snapshot is consumed.
                for x in 1...48 { setLive(liveInput(CGFloat(x), diameter: diameter)) }
                let latest = view.composedInput()!
                check(view.loupe?.scene.point.x == 48 && pixel(latest, x: diameter, y: diameter)[2] > 0.5,
                      "burst tracking encodes the latest point without a stale raster callback at diameter \(diameter)")
                setLive(liveInput(80, diameter: diameter))
                let before = pixel(view.composedInput()!, x: diameter, y: diameter)
                setLive(liveInput(80, diameter: diameter, width: 192))
                let after = pixel(view.composedInput()!, x: diameter, y: diameter)
                check(before[0] > 0.7 && after[0] < 0.1 && after[2] > 0.5,
                      "live lens incorporates film zoom before layout commit at diameter \(diameter)")
            }
            setLive(liveInput(16, diameter: 260))
            let liveBytes = try await renderSurface(view)
            let centre = (32 * 64 + 32) * 4
            check(Int(liveBytes[centre + 2]) > Int(liveBytes[centre]) * 5,
                  "production live graph reaches the 8-bit GPU texture without CGImage readback")
            view.set(preview: preview, image: nil, transmission: 1, flare: 0, brightness: 1)
            check(view.loupe == nil && view.autoResizeDrawable, "leaving live lens restores normal photograph drawable sizing")

            // Four distinct quadrants expose both vertical and horizontal reversal.
            let marker = CIImage(cgImage: image(0.4, 0.01, 0.01)).cropped(to: CGRect(x: 0, y: 32, width: 32, height: 32))
                .composited(over: CIImage(cgImage: image(0.01, 0.4, 0.01)).cropped(to: CGRect(x: 32, y: 32, width: 32, height: 32)))
                .composited(over: CIImage(cgImage: image(0.01, 0.01, 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32)))
                .composited(over: CIImage(cgImage: image(0.25)).cropped(to: bounds))
            let markerImage = context.createCGImage(marker, from: bounds, format: .RGBA8, colorSpace: PhotoOptics.blendSpace)!
            let markerDark = context.createCGImage(PhotoOptics.multiplied(CIImage(cgImage: markerImage), 0.1),
                from: bounds, format: .RGBA8, colorSpace: PhotoOptics.blendSpace)!
            let markerPreview = PhotoPreview(source: markerImage, lit: markerImage, dark: markerDark, flare: image(0))
            let viewportView = OpticalMetalView()
            for scale: CGFloat in [1, 2, 3] {
                let scene = LoupeSceneInput(photos: [LoupeScenePhoto(preview: markerPreview,
                    center: CGPoint(x: 32, y: 32), imageSize: CGSize(width: 64, height: 64))],
                    point: CGPoint(x: 28, y: 35), panelBounds: nil, transmission: 1, flare: 0, brightness: 1)
                let region = CGRect(x: 330, y: 325, width: 150, height: 120)
                var cropped = LoupeDisplayInput(scene: scene, diameter: 810, magnification: 20,
                    displayScale: scale, viewport: region, refractionScale: 0)
                let full = LoupeRenderer.shared.composite(photos: scene.photos, point: scene.point,
                    diameter: 810, magnification: 20, displayScale: scale, transmission: 1, flare: 0, brightness: 1,
                    refractionScale: 0)!
                viewportView.set(preview: nil, image: nil, transmission: 1, flare: 0, brightness: 1, loupe: cropped)
                let graph = viewportView.composedInput()!
                check(graph.extent.size == CGSize(width: 150 * scale, height: 120 * scale) &&
                      viewportView.drawableSize == cropped.pixelSize,
                      "cropped production drawable uses visible rectangular Retina dimensions at \(scale)x")
                var samePixels = true
                for y: CGFloat in [8, 60, 112] {
                    for x: CGFloat in [8, 75, 142] {
                        let actual = pixel(graph, x: x * scale, y: y * scale)
                        let expected = pixel(full, x: (region.minX + x) * scale,
                            y: (810 - region.maxY + y) * scale)
                        samePixels = samePixels && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.002 }
                    }
                }
                check(samePixels, "viewport crop preserves both axes and original source pixels at \(scale)x")
                cropped.refractionScale = 1
                viewportView.set(preview: nil, image: nil, transmission: 1, flare: 0, brightness: 1, loupe: cropped)
                let clear = pixel(graph, x: 75 * scale, y: 60 * scale)
                let bent = pixel(viewportView.composedInput()!, x: 75 * scale, y: 60 * scale)
                check(zip(clear, bent).allSatisfy { abs($0 - $1) < 0.002 },
                      "offscreen glass rim cannot distort the visible photograph centre at \(scale)x")
            }
            let croppedBytes = try await renderSurface(viewportView)
            let croppedCentre = (32 * 64 + 32) * 4
            let expectedCrop = pixel(viewportView.composedInput()!,
                x: viewportView.drawableSize.width / 2, y: viewportView.drawableSize.height / 2)
            let expectedChannel = (0..<3).max { expectedCrop[$0] < expectedCrop[$1] }!
            let gpuChannels = [croppedBytes[croppedCentre + 2], croppedBytes[croppedCentre + 1], croppedBytes[croppedCentre]]
            let gpuChannel = (0..<3).max { gpuChannels[$0] < gpuChannels[$1] }!
            check(expectedChannel == gpuChannel && gpuChannels[gpuChannel] > 80,
                  "cropped live viewport reaches the production GPU surface with the correct source point")
            let markerView = OpticalMetalView()
            func markerFrame(_ transmission: Double, _ flare: Double, brightness: Double = 1) async throws -> [UInt8] {
                markerView.set(preview: markerPreview, image: nil, transmission: transmission, flare: flare, brightness: brightness)
                return try await renderSurface(markerView)
            }
            func correctOrientation(_ bytes: [UInt8]) -> Bool {
                func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                    let i = (y * 64 + x) * 4
                    return (Int(bytes[i + 2]), Int(bytes[i + 1]), Int(bytes[i]))
                }
                let red = rgb(16, 16), green = rgb(48, 16), blue = rgb(16, 48)
                return red.0 > red.1 * 3 && red.0 > red.2 * 3 &&
                    green.1 > green.0 * 3 && green.1 > green.2 * 3 &&
                    blue.2 > blue.0 * 3 && blue.2 > blue.1 * 3
            }
            let off = try await markerFrame(0, 0)
            check(correctOrientation(off), "unlit production frame has correct orientation and visible content")
            check(markerView.cachedStableTexture == nil, "unlit first draw does not also compute a lit cache")
            let peak = try await markerFrame(1, 1)
            check(correctOrientation(peak), "ignition peak has correct orientation and visible content")
            check(markerView.cachedStableTexture == nil, "animation does not build or read a stable texture")
            let steady = try await markerFrame(1, 0)
            check(correctOrientation(steady), "first stable production frame has correct orientation")
            check(markerView.cachedStableTexture != nil, "GPU completion publishes the successfully copied stable frame")
            let cachedTexture = markerView.cachedStableTexture
            let cached = try await markerFrame(1, 0)
            check(cached == steady && markerView.cachedStableTexture === cachedTexture,
                  "stable cache reuse preserves every display byte without rebuilding")
            let secondOff = try await markerFrame(0, 0)
            let secondPeak = try await markerFrame(1, 1)
            let secondSteady = try await markerFrame(1, 0)
            check(correctOrientation(secondOff) && correctOrientation(secondPeak) && secondSteady == steady,
                  "off, on and settled frames remain aligned after a cache already exists")
            check(peak[centre + 2] > steady[centre + 2], "production SDR frame retains ignition overexposure")
            let brighter = try await markerFrame(1, 0, brightness: 1.6)
            check(brighter != steady && correctOrientation(brighter), "brightness invalidates the cache without flipping the photograph")

            // A stale completion must not publish pixels belonging to a replaced photograph.
            let staleView = OpticalMetalView()
            staleView.set(preview: markerPreview, image: nil, transmission: 1, flare: 0, brightness: 1)
            let staleTexture = gpu.makeTexture(descriptor: descriptor)!, staleBuffer = queue.makeCommandBuffer()!
            check(staleView.encode(into: staleTexture, commandBuffer: staleBuffer, renderer: renderer), "replacement regression encodes initial cache")
            staleView.set(preview: preview, image: nil, transmission: 0, flare: 0, brightness: 1)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                staleBuffer.addCompletedHandler { _ in DispatchQueue.main.async { continuation.resume() } }
                staleBuffer.commit()
            }
            check(staleView.cachedStableTexture == nil, "stale GPU completion cannot overwrite a replacement photograph")

            // Drawable size changes: cached output must match a fresh, uncached surface.
            func renderSized(_ surface: OpticalMetalView, _ width: Int, _ height: Int) async throws -> [UInt8] {
                let sized = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                sized.usage = [.shaderRead, .shaderWrite, .renderTarget]; sized.storageMode = .shared
                let texture = gpu.makeTexture(descriptor: sized)!, buffer = queue.makeCommandBuffer()!
                precondition(surface.encode(into: texture, commandBuffer: buffer, renderer: renderer), "sized surface failed to encode")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    buffer.addCompletedHandler { _ in continuation.resume() }
                    buffer.commit()
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
                precondition(buffer.status == .completed, "GPU rejected sized surface encoding")
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                return bytes
            }
            let resizedView = OpticalMetalView()
            resizedView.set(preview: markerPreview, image: nil, transmission: 1, flare: 0, brightness: 1)
            for (width, height) in [(64, 64), (128, 96), (64, 64)] {
                let first = try await renderSized(resizedView, width, height)
                let reused = try await renderSized(resizedView, width, height)
                let fresh = OpticalMetalView()
                fresh.set(preview: markerPreview, image: nil, transmission: 1, flare: 0, brightness: 1)
                let expected = try await renderSized(fresh, width, height)
                check(first == expected && reused == expected && resizedView.cachedStableTexture?.width == width
                      && resizedView.cachedStableTexture?.height == height,
                      "cached surface matches an uncached surface after resizing to \(width)x\(height)")
            }

            // Retry budget and its production wiring, driven by an injected scheduler.
            var retry = OpticalRetryBudget()
            retry.beginNewInput()
            let previousRevision = retry.revision
            check(retry.nextDelay() == 1.0 / 60.0, "first retry is deferred")
            check(retry.nextDelay() == 0.05, "second retry backs off")
            check(retry.nextDelay() == 0.15, "third retry backs off")
            check(retry.nextDelay() == nil, "retry budget is finite")
            check(retry.nextDelay() == nil, "exhausted budget stays exhausted")
            retry.beginNewInput()
            check(retry.revision != previousRevision && retry.attempts == 0,
                  "new input invalidates stale work and rearms retries")
            _ = retry.nextDelay()
            retry.succeeded()
            check(retry.attempts == 0, "successful work clears failure count")

            var queued: [(delay: TimeInterval, work: () -> Void)] = []
            let liveScheduler = OpticalMetalView.scheduleRetry
            OpticalMetalView.scheduleRetry = { queued.append(($0, $1)) }
            let retryView = OpticalMetalView()
            retryView.set(preview: preview, image: nil, transmission: 1, flare: 0, brightness: 1)
            let firstRevision = retryView.retry.revision
            retryView.noteDrawFailure("check")
            check(queued.count == 1 && queued[0].delay == 1.0 / 60.0 && retryView.pendingRetry != nil,
                  "visible draw failure schedules one deferred redraw")
            retryView.noteDrawFailure("check")
            check(queued.count == 1 && retryView.retry.attempts == 1,
                  "repeated failures coalesce into the pending retry")
            let staleRetry = queued.removeFirst().work
            retryView.set(preview: markerPreview, image: nil, transmission: 1, flare: 0, brightness: 1)
            check(retryView.retry.revision != firstRevision && retryView.pendingRetry == nil && retryView.retry.attempts == 0,
                  "new input cancels the pending retry and rearms the budget")
            retryView.noteDrawFailure("check")
            let currentToken = retryView.pendingRetry
            staleRetry()
            check(currentToken != nil && retryView.pendingRetry == currentToken,
                  "old input callback cannot affect the new input's retry")
            queued.removeFirst().work()
            check(retryView.pendingRetry == nil && queued.isEmpty,
                  "windowless view consumes its retry without polling")
            retryView.noteDrawFailure("check")
            check(queued.count == 1 && queued[0].delay == 0.05, "next failure of the same input backs off")
            queued.removeFirst().work()
            retryView.noteDrawFailure("check")
            check(queued.count == 1 && queued[0].delay == 0.15, "third failure of the same input backs off")
            queued.removeFirst().work()
            retryView.noteDrawFailure("check")
            check(queued.isEmpty && retryView.pendingRetry == nil, "production retries stop at the budget")
            retryView.set(preview: markerPreview, image: nil, transmission: 1, flare: 0, brightness: 1)
            retryView.noteDrawFailure("check")
            check(queued.isEmpty, "unchanged SwiftUI updates do not rearm an exhausted budget")
            retryView.set(preview: markerPreview, image: nil, transmission: 0, flare: 0, brightness: 1)
            retryView.noteDrawFailure("check")
            check(queued.count == 1, "changed input can retry again after exhaustion")
            let supersededRetry = queued.removeFirst().work
            retryView.noteDrawSuccess()
            check(retryView.pendingRetry == nil && retryView.retry.attempts == 0, "GPU success clears failure state")
            supersededRetry()
            check(retryView.pendingRetry == nil && queued.isEmpty, "success invalidates an already queued retry")
            retryView.noteDrawFailure("check")
            let detachRevision = retryView.retry.revision
            let detachedRetry = queued.removeFirst().work
            retryView.viewDidMoveToWindow()
            detachedRetry()
            check(retryView.retry.revision != detachRevision && retryView.pendingRetry == nil && queued.isEmpty,
                  "window change cancels the queued retry")

            // Drive the production batch's allocation-failure path without a window.
            var bufferRequests = 0
            func drawWithoutBuffer(_ views: [OpticalMetalView]) {
                OpticalMetalView.drawVisible(views, renderer: renderer, makeCommandBuffer: {
                    bufferRequests += 1
                    return nil
                })
            }
            let sizeRetryView = OpticalMetalView()
            sizeRetryView.set(preview: preview, image: nil, transmission: 1, flare: 0, brightness: 1)
            sizeRetryView.autoResizeDrawable = false
            sizeRetryView.drawableSize = CGSize(width: 64, height: 64)
            drawWithoutBuffer([sizeRetryView])
            let sizeRevision = sizeRetryView.retry.revision
            check(queued.count == 1 && queued[0].delay == 1.0 / 60.0,
                  "command buffer allocation failure schedules the first retry")
            queued.removeFirst().work()
            for delay in [0.05, 0.15] {
                drawWithoutBuffer([sizeRetryView])
                check(queued.count == 1 && queued[0].delay == delay && sizeRetryView.retry.revision == sizeRevision,
                      "same-size allocation failure retains its backoff at \(delay)")
                queued.removeFirst().work()
            }
            drawWithoutBuffer([sizeRetryView])
            check(queued.isEmpty && sizeRetryView.retry.attempts == 3 && sizeRetryView.pendingRetry == nil,
                  "same-size allocation failures stop after three retries")
            sizeRetryView.drawableSize = CGSize(width: 128, height: 96)
            drawWithoutBuffer([sizeRetryView])
            check(queued.count == 1 && queued[0].delay == 1.0 / 60.0 &&
                  sizeRetryView.retry.revision != sizeRevision && sizeRetryView.retry.attempts == 1,
                  "size change rearms an exhausted budget before command buffer allocation")
            let oldSizeRetry = queued.removeFirst().work
            sizeRetryView.drawableSize = CGSize(width: 192, height: 128)
            drawWithoutBuffer([sizeRetryView])
            let newSizeToken = sizeRetryView.pendingRetry
            let newSizeRevision = sizeRetryView.retry.revision
            oldSizeRetry()
            check(queued.count == 1 && newSizeToken != nil && sizeRetryView.pendingRetry == newSizeToken,
                  "old-size callback cannot clear the new size's pending retry")
            drawWithoutBuffer([sizeRetryView])
            check(queued.count == 1 && sizeRetryView.pendingRetry == newSizeToken &&
                  sizeRetryView.retry.revision == newSizeRevision && sizeRetryView.retry.attempts == 1,
                  "repeated same-size batches coalesce without resetting retry state")
            queued.removeFirst().work()

            let emptyView = OpticalMetalView()
            emptyView.autoResizeDrawable = false
            emptyView.drawableSize = CGSize(width: 64, height: 64)
            let zeroWidthView = OpticalMetalView(), zeroHeightView = OpticalMetalView()
            for view in [zeroWidthView, zeroHeightView] {
                view.set(preview: preview, image: nil, transmission: 1, flare: 0, brightness: 1)
                view.autoResizeDrawable = false
            }
            zeroWidthView.drawableSize = CGSize(width: 0, height: 64)
            zeroHeightView.drawableSize = CGSize(width: 64, height: 0)
            let idleViews = [emptyView, zeroWidthView, zeroHeightView]
            let requestsBeforeIdle = bufferRequests
            let idleRevisions = idleViews.map { $0.retry.revision }
            drawWithoutBuffer(idleViews)
            check(bufferRequests == requestsBeforeIdle && queued.isEmpty &&
                  idleViews.allSatisfy { $0.retry.attempts == 0 && $0.pendingRetry == nil } &&
                  idleViews.map { $0.retry.revision } == idleRevisions,
                  "empty or zero-size surfaces skip allocation without spending retry budgets")
            drawWithoutBuffer([sizeRetryView] + idleViews)
            check(bufferRequests == requestsBeforeIdle + 1 && queued.count == 1 && queued[0].delay == 0.05 &&
                  sizeRetryView.pendingRetry != nil && idleViews.allSatisfy { $0.pendingRetry == nil && $0.retry.attempts == 0 },
                  "mixed batch allocation failure retries only surfaces with valid input and size")
            queued.removeFirst().work()
            OpticalMetalView.scheduleRetry = liveScheduler
        }
        print("\(count) optics checks passed")
    }
}
