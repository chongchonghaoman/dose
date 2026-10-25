import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct LightChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var passed = 0
    static var failed = 0
    static func require(_ yes: @autoclosure () -> Bool, _ message: String) throws {
        if !yes() { throw Failure(description: message) }
    }
    static func check(_ name: String, _ work: () async throws -> Void) async {
        do { try await work(); passed += 1; print("PASS  \(name)") }
        catch { failed += 1; print("FAIL  \(name): \(error)") }
    }
    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LightResponse-" + UUID().uuidString)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("swatches.png")
        let swatches: [[CGFloat]] = [[0,0,0,1],[0.02,0.02,0.02,1],[0.45,0.45,0.45,1],[0.8,0.8,0.8,1],
                                    [0.94,0.94,0.94,1],[0.98,0.98,0.98,1],[0.68,0.18,0.1,1],
                                    [0.2,0.65,0.3,1],[0.18,0.3,0.75,1]]
        try! writeFixture(url, colors: swatches)
        let before = try! Data(contentsOf: url)
        let store = PhotoStore()
        guard let preview = await store.preview(url) else { print("FAIL  preview failed"); exit(1) }
        let halo = CIImage(cgImage: preview.flare).applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: preview.lit)
        ])
        let peakImage = CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(halo,
            from: halo.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))!
        let source = pixels(preview.source), lit = pixels(preview.lit), peak = pixels(peakImage)
        let boosted = pixels(preview.boosted), glow = pixels(preview.flare)
        func sample(_ bytes: [UInt8], _ index: Int) -> [Double] {
            let offset = (90 * preview.source.width + index * 120 + 60) * 4
            return (0..<3).map { Double(bytes[offset + $0]) / 255 }
        }
        for index in 0..<swatches.count {
            print("      swatch \(index): source=\(sample(source,index)) lit=\(sample(lit,index)) peak=\(sample(peak,index))")
        }
        await check("Black film borders remain black in steady and peak previews") {
            for image in [lit, peak, boosted] {
                try require(sample(image,0).max()! < 0.012, "black border washed out")
                let black = sample(image,1)
                try require(black.max()! < 0.03, "near-black border lifted")
                try require(black.max()! - black.min()! < 0.006, "near-black gray acquired tint")
            }
        }
        await check("Transmission caches retain source tones before display-time lamp gain") {
            for index in [2,3,6,7,8] {
                let a = luminance(sample(source,index)), b = luminance(sample(lit,index)), c = luminance(sample(boosted,index))
                try require(abs(b - a) <= 2.0 / 255, "default lamp remapped source tones at swatch \(index)")
                try require(abs(c - a) <= 2.0 / 255, "scatter cache remapped uniform tones at swatch \(index)")
            }
        }
        await check("Highlight shoulder retains gradations without white clipping") {
            for bytes in [lit, peak, boosted] {
                try require(sample(bytes,3)[0] < sample(bytes,4)[0], "80/94 percent merged")
                try require(sample(bytes,4)[0] < sample(bytes,5)[0], "94/98 percent merged")
                try require(sample(bytes,5)[0] < 1, "98 percent highlight hard-clipped")
            }
        }
        await check("Neutral grays and colored swatches retain hue") {
            for bytes in [lit, peak, boosted] {
                let gray = sample(bytes,2)
                try require(gray.max()! - gray.min()! < 0.012, "gray gained a tint")
                for index in [6,7,8] {
                    let a = sample(source,index).map(linear), b = sample(bytes,index).map(linear)
                    let ra = a.map { $0/a.max()! }, rb = b.map { $0/b.max()! }
                    try require(zip(ra,rb).allSatisfy { abs($0 - $1) < 0.035 }, "channel ratios shifted for \(index)")
                }
            }
        }
        await check("Unlit film is darker than before but retains faint scene information") {
            let input = CIImage(cgImage: preview.source)
            let expected = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x:0.075,y:0,z:0,w:0),
                "inputGVector": CIVector(x:0,y:0.075,z:0,w:0),
                "inputBVector": CIVector(x:0,y:0,z:0.075,w:0),
                "inputBiasVector": CIVector(x:0.003,y:0.003,z:0.003,w:0)])
            let image = CIContext(options:[.cacheIntermediates:false]).createCGImage(expected, from:input.extent, format:.RGBA8, colorSpace:CGColorSpace(name:CGColorSpace.displayP3))!
            let old = pixels(image), dark = pixels(preview.dark)
            for index in [2,3,4,5,6,7,8] {
                let oldL = luminance(sample(old,index)), newL = luminance(sample(dark,index))
                try require(newL > 0.01 && newL < oldL * 0.83, "unlit film is too bright or entirely black")
                try require(newL < luminance(sample(lit,index)) * 0.3, "unlit film remains too readable")
            }
            try require(sample(dark,0).max()! < 0.025, "reflection lifts the film black")
        }
        await check("All previews preserve geometry and original file bytes") {
            for image in [preview.lit, preview.dark, preview.flare, preview.boosted] {
                try require(image.width == preview.source.width && image.height == preview.source.height, "size changed")
            }
            _ = await store.thumbnail(url)
            _ = await store.preview(url)
            let after = try Data(contentsOf:url)
            try require(before == after, "source file was rewritten")
            try require(max(preview.source.width, preview.source.height) <= 2200, "preview bound exceeded")
        }
        await check("Response starts dark, reaches one peak, and settles exactly") {
            let initial = LightResponse.sample(elapsed:0,isLit:true)
            let peak = LightResponse.sample(elapsed:LightResponse.peakTime,isLit:true)
            let steady = LightResponse.sample(elapsed:LightResponse.settlingDuration,isLit:true)
            try require(initial.transmission == 0 && initial.flare == 0 && initial.glow == 0, "start flashes")
            try require(peak.transmission == 1 && peak.flare == 1 && peak.glow > LightResponse.steadyGlow, "edge light has no ignition peak")
            try require(LightResponse.panelWhite(brightness: 1, flare: peak.flare) >
                        LightResponse.panelWhite(brightness: 1) + 0.06, "panel has no visible recovery headroom")
            try require(steady.transmission == 1 && steady.flare == 0 && steady.glow == LightResponse.steadyGlow, "steady incorrect")
            var last = peak
            for n in 1...3000 {
                let current = LightResponse.sample(elapsed:LightResponse.peakTime + Double(n)/1000,isLit:true)
                try require(current.flare <= last.flare && current.glow <= last.glow, "response rebounds")
                try require(current.transmission == 1 && current.glow >= LightResponse.steadyGlow, "response falls below stable light")
                last = current
            }
        }
        await check("Off and reduced-motion states never flash or oscillate") {
            for time in [-1.0,0,0.04,0.11,0.4,1.2,4,.infinity,.nan] {
                let off = LightResponse.sample(elapsed:time,isLit:false)
                try require(off.transmission == 0 && off.flare == 0 && off.glow == 0,"off not zero")
                let reduced = LightResponse.sample(elapsed:time,isLit:true,reduceMotion:true)
                try require(reduced.transmission == 1 && reduced.flare == 0 && reduced.glow == LightResponse.steadyGlow,"reduced-motion flashes")
                let normal = LightResponse.sample(elapsed:time,isLit:true)
                try require([normal.transmission,normal.flare,normal.glow].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },"nonfinite/range error")
            }
        }
        await check("Panel, photographs and edge light share one brief peak and recovery") {
            let lampOn = LightResponse.sample(elapsed: 0.12, isLit: true)
            let peak = LightResponse.sample(elapsed: LightResponse.peakTime, isLit: true)
            let afterPeak = LightResponse.sample(elapsed: 0.28, isLit: true)
            let early = LightResponse.sample(elapsed: 0.45, isLit: true)
            let late = LightResponse.sample(elapsed: 0.80, isLit: true)
            let settled = LightResponse.sample(elapsed: 1.10, isLit: true)
            try require(lampOn.transmission == 1 && lampOn.glow > LightResponse.steadyGlow, "lamp takes too long to illuminate")
            try require(lampOn.flare < peak.flare && afterPeak.flare == peak.flare, "bloom must linger briefly at full strength")
            try require(LightResponse.sample(elapsed: 0.33, isLit: true).flare > 0.98, "bloom starts falling too abruptly")
            try require(LightResponse.sample(elapsed: 1.05, isLit: true).flare > 0, "bloom tail ends too soon")
            try require(abs(LightResponse.sample(elapsed: 0.69, isLit: true).flare - 0.5) < 0.000001, "recovery midpoint shifted")
            try require(early.flare > 0.8 && early.flare < afterPeak.flare, "early adaptation is abrupt")
            try require(late.flare > 0 && late.flare < early.flare && settled.flare == 0, "falloff is not gradual")
            for power in [0.1, 1, 1.6] {
                let base = LightResponse.panelWhite(brightness: power)
                var previousPanel = LightResponse.panelWhite(brightness: power, flare: peak.flare)
                var previousGlow = peak.glow
                var previousExposure = LightResponse.photoExposureStops(flare: peak.flare, brightness: power)
                for sample in [afterPeak, early, late, settled] {
                    let panel = LightResponse.panelWhite(brightness: power, flare: sample.flare)
                    let exposure = LightResponse.photoExposureStops(flare: sample.flare, brightness: power)
                    try require(sample.transmission == 1 && panel >= base && panel <= previousPanel &&
                                sample.glow <= previousGlow && exposure <= previousExposure,
                                "lighting materials recover out of order")
                    previousPanel = panel; previousGlow = sample.glow; previousExposure = exposure
                }
                try require(previousPanel == base && previousGlow == LightResponse.steadyGlow && previousExposure == 0,
                            "materials fail to reach their exact steady state together")
            }
        }
        await check("Light response has no jumps or velocity breaks at phase boundaries") {
            let h = 0.00001
            for boundary in [0, LightResponse.lampRiseDuration, LightResponse.peakTime, LightResponse.bloomReleaseTime, LightResponse.settlingDuration] {
                let a = LightResponse.sample(elapsed: boundary - h, isLit: true)
                let b = LightResponse.sample(elapsed: boundary, isLit: true)
                let c = LightResponse.sample(elapsed: boundary + h, isLit: true)
                for (left, center, right) in [(a.transmission,b.transmission,c.transmission),
                                               (a.flare,b.flare,c.flare), (a.glow,b.glow,c.glow)] {
                    try require(abs(center - left) < 0.001 && abs(right - center) < 0.001, "visible jump at \(boundary)")
                    try require(abs((center - left) / h - (right - center) / h) < 0.02, "velocity break at \(boundary)")
                }
            }
        }
        await check("Switch-on halo leaves shadow and midtone exposure stable") {
            for index in [0,1,2,6,7,8] {
                try require(sample(glow,index).max()! < 0.005, "halo contains a midtone exposure lift")
                try require(zip(sample(peak,index), sample(lit,index)).allSatisfy { abs($0 - $1) <= 1.0 / 255 },
                            "photo exposure changes at swatch \(index)")
            }
        }
        await check("Bright highlights show visible bloom without an overall exposure dip") {
            let changes = [3,4,5].map { luminance(sample(peak,$0)) - luminance(sample(lit,$0)) }
            try require(changes.max()! > 0.012, "switch-on bloom is too faint")
            try require(changes.allSatisfy { $0 >= 0 && $0 < 0.045 }, "bloom overwhelms highlight detail")
        }
        await check("Low lamp brightness also reduces the switch-on transient") {
            let dim = LightResponse.photoGlowMix(flare: 1, brightness: 0.1)
            let normal = LightResponse.photoGlowMix(flare: 1, brightness: 1)
            try require(dim > 0 && dim < 0.4 && normal == 1, "dim lamp has a full-strength transient")
            let dimPanelRise = LightResponse.panelWhite(brightness: 0.1, flare: 1) - LightResponse.panelWhite(brightness: 0.1)
            let normalPanelRise = LightResponse.panelWhite(brightness: 1, flare: 1) - LightResponse.panelWhite(brightness: 1)
            try require(dimPanelRise > 0 && dimPanelRise < normalPanelRise * 0.4, "dim panel has a full-strength flash")
            var previous = 0.0
            for step in 10...160 {
                let value = LightResponse.photoGlowMix(flare: 0.6, brightness: Double(step) / 100)
                try require(value >= previous && value <= 1, "transient brightness reverses or clips")
                previous = value
            }
        }
        await check("Continuous brightness keeps panel and photo levels monotonic") {
            var previousPanel = 0.0, previousLevel = 0.0, previousMix = 0.0
            for step in 10...160 {
                let power = Double(step) / 100
                let panel = LightResponse.panelWhite(brightness: power)
                let level = LightResponse.photoLevel(brightness: power)
                let mix = LightResponse.photoBrightnessMix(brightness: power)
                try require(panel >= previousPanel && level >= previousLevel && mix >= previousMix, "brightness reverses")
                try require(panel <= 1 && level <= 1 && mix <= 1, "brightness clips")
                previousPanel = panel; previousLevel = level; previousMix = mix
            }
            try require(LightResponse.photoBrightnessMix(brightness: 1.6) > 0.65, "high brightness does not brighten photos")
            for value in [-1.0, .nan, .infinity] {
                try require(LightResponse.panelWhite(brightness: value).isFinite &&
                            LightResponse.photoLevel(brightness: value).isFinite &&
                            LightResponse.photoBrightnessMix(brightness: value).isFinite, "invalid brightness escapes")
            }
        }
        await check("Comparison selects source or cached transmission without processing again") {
            let original = preview.viewing(transmitted: false), transmitted = preview.viewing(transmitted: true)
            try require(original.lit === preview.source && transmitted.lit === preview.lit,
                        "comparison selected the wrong image")
            try require(original.dark === transmitted.dark && original.flare === transmitted.flare,
                        "comparison changed the off state or ignition")
            let cached = await store.preview(url)
            try require(cached?.lit === preview.lit, "switching processed the photo again")
            let after = try Data(contentsOf: url)
            try require(after == before, "transmission modified the original file")
        }
        await check("Flat color and gray areas keep original levels and saturation") {
            for index in 0..<swatches.count {
                try require(zip(sample(source,index), sample(lit,index)).allSatisfy { abs($0 - $1) <= 2.0 / 255 },
                            "source color or tonal level changed at swatch \(index)")
            }
        }
        await check("Source midtone edge contrast remains unchanged without sharpening") {
            let detailURL = root.appendingPathComponent("source-detail.png")
            try writeFixture(detailURL, colors: [[0.43,0.43,0.43,1],[0.49,0.49,0.49,1]])
            let detail = await store.preview(detailURL)!
            let base = pixels(detail.source), transmitted = pixels(detail.lit)
            for x in 100...140 {
                let index = (90 * detail.source.width + x) * 4
                try require((0..<3).allSatisfy { abs(Int(base[index + $0]) - Int(transmitted[index + $0])) <= 2 },
                            "midtones gained a contrast halo or were softened")
            }
        }
        await check("Light spills just outside highlights while bright interiors retain detail") {
            let boundaryURL = root.appendingPathComponent("light-boundary.png")
            try writeFixture(boundaryURL, colors: [[0.45,0.45,0.45,1],[0.95,0.95,0.95,1],
                                                [0.45,0.45,0.45,1],[0.02,0.02,0.02,1],
                                                [0.95,0.95,0.95,1],[0,0,0,1]])
            let boundary = await store.preview(boundaryURL)!
            let base = pixels(boundary.source), transmitted = pixels(boundary.lit)
            func change(_ x: Int) -> Double {
                let i = (90 * boundary.source.width + x) * 4
                return Double(Int(transmitted[i]) - Int(base[i])) / 255
            }
            try require(change(118) > 0.003 && change(241) > 0.003, "bright boundaries emit no light")
            try require(abs(change(60)) <= 2.0 / 255 && abs(change(180)) <= 2.0 / 255,
                        "light washed across the photo or compressed its highlights")
            try require(change(118) < 0.035 && change(241) < 0.035, "light spill obscures edge detail")
            for x in [478, 601] {
                try require(change(x) > 0.015 && change(x) < 0.25, "near-aperture scatter is absent or overwhelms the film")
            }
            for x in [420, 660] {
                try require(abs(change(x)) <= 2.0 / 255, "scatter washes across distant black film")
            }
        }
        let apertureURL = root.appendingPathComponent("apertures.png")
        try! writeApertures(apertureURL)
        let apertures = await store.preview(apertureURL)!
        let apertureSource = pixels(apertures.source), apertureLit = pixels(apertures.lit)
        let apertureGlow = pixels(apertures.flare)
        func apertureSample(_ bytes: [UInt8], _ x: Int) -> Double {
            Double(bytes[(240 * apertures.source.width + x) * 4]) / 255
        }
        await check("Aperture scatter decays smoothly into nearby black film") {
            var previous = 1.0
            for x in 228...285 {
                let delta = apertureSample(apertureLit, x) - apertureSample(apertureSource, x)
                try require(delta >= 0 && delta <= previous + 1.0 / 255, "scatter has a ring or hard cutoff")
                previous = delta
            }
            let near = apertureSample(apertureLit, 230) - apertureSample(apertureSource, 230)
            let outer = apertureSample(apertureLit, 240) - apertureSample(apertureSource, 240)
            try require(near > 0.04 && near < 0.25 && outer > 0.003 && outer < near, "soft rim and outer diffusion are missing")
            for x in [80, 300, 500, 680] {
                try require(abs(apertureSample(apertureLit, x) - apertureSample(apertureSource, x)) <= 2.0 / 255, "remote film fogged")
            }
        }
        await check("Higher lamp scatter grows locally without fogging distant film") {
            let high = pixels(apertures.boosted)
            let near = apertureSample(high, 236) - apertureSample(apertureSource, 236)
            let normal = apertureSample(apertureLit, 236) - apertureSample(apertureSource, 236)
            try require(near > normal * 1.5 && near < 0.28, "stronger lamp has no distinct local spill")
            for x in [80, 300, 500, 680] {
                try require(abs(apertureSample(high, x) - apertureSample(apertureSource, x)) <= 2.0 / 255, "high power fogs distant film")
            }
        }
        await check("Aperture interiors retain brightness and original geometry") {
            for x in [196, 204, 212, 376, 384, 392] {
                try require(abs(apertureSample(apertureLit, x) - apertureSample(apertureSource, x)) <= 2.0 / 255, "hole interior dimmed or clipped")
            }
            for image in [apertures.lit, apertures.flare, apertures.boosted] {
                try require(image.width == apertures.source.width && image.height == apertures.source.height, "aperture geometry changed")
            }
        }
        await check("Ignition spreads beyond apertures and settles onto persistent transmission") {
            let x = 236
            let base = apertureSample(apertureLit, x)
            let halo = apertureSample(apertureGlow, x)
            let source = apertureSample(apertureSource, x)
            try require(base > source + 0.01 && halo > 0.02, "ignition or steady scatter missing beside an aperture")
            func level(_ time: Double) -> Double {
                let mix = LightResponse.photoGlowMix(flare: LightResponse.sample(elapsed: time, isLit: true).flare, brightness: 1)
                return base + (1 - base) * halo * mix
            }
            try require(level(0.28) == level(LightResponse.peakTime), "ignition dims immediately")
            try require(level(0.45) > level(0.80) && level(0.80) > level(1.10), "excess scatter does not clear gradually")
            try require(level(1.10) == base && base > source, "stable backlight disappears after settling")
            try require(apertureSample(apertureGlow, 300) <= 2.0 / 255, "ignition fog spreads through the whole frame")
        }
        await check("Original comparison removes persistent scatter without regenerating the preview") {
            let original = apertures.viewing(transmitted: false)
            try require(original.lit === apertures.source, "original still includes transmission")
            try require(apertureSample(pixels(original.lit), 230) < apertureSample(apertureLit, 230), "comparison does not remove the aperture rim")
            let cached = await store.preview(apertureURL)
            try require(cached?.lit === apertures.lit && cached?.flare === apertures.flare, "scatter recalculated for a cached image")
        }
        await check("Warm and saturated colors preserve original channel relationships") {
            let colorURL = root.appendingPathComponent("source-colors.png")
            try writeFixture(colorURL, colors: [[0.65,0.46,0.37,1], [0.40,0.52,0.45,1],
                                               [0.38,0.45,0.60,1], [0.95,0.04,0.02,1]])
            let color = await store.preview(colorURL)!
            let base = pixels(color.source), transmitted = pixels(color.lit)
            for swatch in 0..<4 {
                let i = (90 * color.source.width + swatch * 120 + 60) * 4
                try require((0..<3).allSatisfy { abs(Int(base[i + $0]) - Int(transmitted[i + $0])) <= 2 },
                            "warm or saturated color changed")
            }
        }
        print("RESULT \(passed) passed; \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
    static func writeFixture(_ url: URL, colors: [[CGFloat]]) throws {
        let context = CGContext(data:nil,width:colors.count*120,height:180,bitsPerComponent:8,bytesPerRow:colors.count*480,
                                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (index,color) in colors.enumerated() {
            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: color)!)
            context.fill(CGRect(x:index*120,y:0,width:120,height:180))
        }
        let output = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(output,context.makeImage()!,nil)
        try require(CGImageDestinationFinalize(output),"fixture write failed")
    }
    static func writeApertures(_ url: URL) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 720, height: 480, bitsPerComponent: 8, bytesPerRow: 720 * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [0.016, 0.016, 0.016, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
        context.setFillColor(CGColor(colorSpace: space, components: [0.97, 0.97, 0.97, 1])!)
        for x in [180, 360] {
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: 208, width: 48, height: 64),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
        }
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        try require(CGImageDestinationFinalize(output), "aperture fixture write failed")
    }
    static func pixels(_ image: CGImage, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> [UInt8] {
        var result = [UInt8](repeating:0,count:image.width*image.height*4)
        result.withUnsafeMutableBytes { buffer in
            let context = CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                                    space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return result
    }
    static func luminance(_ rgb:[Double]) -> Double { 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2] }
    static func linear(_ x:Double) -> Double { x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
}
