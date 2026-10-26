import CoreImage
import Foundation

@main
struct LoupeChecks {
    static func main() throws {
        let size = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                bytesPerRow: size * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.85, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for i in stride(from: 0, to: size, by: 24) {
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: i, y: 0, width: 3, height: size))
            context.fill(CGRect(x: 0, y: i, width: size, height: 3))
        }
        let image = context.makeImage()!
        let preview = PhotoPreview(source: image, lit: image, dark: image, flare: image)
        func render(_ point: CGPoint, refracts: Bool) -> CGImage {
            LoupeRenderer.shared.render(preview: preview, point: point, imageSize: CGSize(width: 600, height: 600),
                diameter: 260, magnification: 2.5, displayScale: 2, transmission: 1, flare: 0, brightness: 1,
                refracts: refracts)!
        }
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let normal = render(CGPoint(x: 300, y: 300), refracts: false)
        let glass = render(CGPoint(x: 300, y: 300), refracts: true)
        precondition(glass.width == 520 && glass.height == 520, "lens was not rendered at screen resolution")
        print("PASS lens output respects display scale")
        let a = pixels(normal), b = pixels(glass)
        var centre = 0.0, centreN = 0.0, edge = 0.0, edgeN = 0.0
        var shoulder = 0.0, shoulderN = 0.0
        for y in 0..<520 { for x in 0..<520 {
            let r = hypot(Double(x) - 260, Double(y) - 260) / 260
            let index = (y * 520 + x) * 4
            let difference = (0..<3).reduce(0.0) { $0 + abs(Double(a[index + $1]) - Double(b[index + $1])) } / 3
            if r < 0.70 { centre += difference; centreN += 1 }
            if r > 0.78 && r < 0.90 { shoulder += difference; shoulderN += 1 }
            if r > 0.94 && r < 0.995 { edge += difference; edgeN += 1 }
        } }
        precondition(centre / centreN < 1, "refraction disturbed the clear centre")
        precondition(edge / edgeN > 0.1, "outer glass did not refract image pixels")
        print("PASS clear centre preserves detail; outer glass refracts the grid (mean difference \(edge / edgeN))")
        precondition(shoulder / shoulderN > 0.2, "glass shoulder lacks a gradual change in local magnification")
        print("PASS clear centre transitions into visible shoulder curvature")
        func fadedGlass(_ strength: CGFloat) -> [UInt8] {
            let photo = LoupeScenePhoto(preview: preview, center: CGPoint(x: 300, y: 300),
                imageSize: CGSize(width: 600, height: 600))
            return pixels(LoupeRenderer.shared.render(photos: [photo], point: CGPoint(x: 300, y: 300),
                diameter: 260, magnification: 2.5, displayScale: 2, transmission: 1, flare: 0, brightness: 1,
                refractionScale: strength)!)
        }
        precondition(fadedGlass(0) == a, "disabled refraction changes source pixels")
        print("PASS explicit zero-strength fallback preserves actual source pixels")
        let half = fadedGlass(0.45)
        var fullDifference = 0.0, halfDifference = 0.0
        for y in 0..<520 { for x in 0..<520 {
            let r = hypot(Double(x) - 260, Double(y) - 260) / 260
            if r > 0.94 && r < 0.995 {
                let i = (y * 520 + x) * 4
                fullDifference += abs(Double(a[i]) - Double(b[i]))
                halfDifference += abs(Double(a[i]) - Double(half[i]))
            }
        } }
        precondition(halfDifference > fullDifference * 0.2 && halfDifference < fullDifference * 0.8,
            "approach refraction does not fade continuously")
        print("PASS actual rim refraction fades with the shared approach progress")
        let crossing = pixels(render(CGPoint(x: 0, y: 0), refracts: true))
        precondition(stride(from: 3, to: crossing.count, by: 4).allSatisfy { crossing[$0] == 255 }, "photo edge left a transparent seam")
        print("PASS lens across photo and mount edges stays fully opaque")
        // Encode horizontal source position as a ramp. A glass rim must not
        // repeat, reverse, jump, or stretch a narrow source strip into a ring.
        for x in 0..<size {
            let value = min(1, max(0, Double(x - 240) / 120))
            context.setFillColor(CGColor(red: value, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: size))
        }
        let ramp = context.makeImage()!
        let rampPreview = PhotoPreview(source: ramp, lit: ramp, dark: ramp, flare: ramp)
        func rampPixels(_ refracts: Bool) -> [UInt8] {
            pixels(LoupeRenderer.shared.render(preview: rampPreview, point: CGPoint(x: 300, y: 300),
                imageSize: CGSize(width: 600, height: 600), diameter: 260, magnification: 2.5,
                displayScale: 2, transmission: 1, flare: 0, brightness: 1, refracts: refracts)!)
        }
        let straightRamp = rampPixels(false), glassRamp = rampPixels(true)
        var largestShift = 0
        for x in 261..<515 {
            let i = (260 * 520 + x) * 4
            let step = Int(glassRamp[i]) - Int(glassRamp[i - 4])
            precondition(step >= -1 && step <= 3, "rim contains a radial fold or sampling seam")
            largestShift = max(largestShift, abs(Int(glassRamp[i]) - Int(straightRamp[i])))
        }
        precondition(largestShift >= 1 && largestShift <= 5, "edge refraction is absent or excessive")
        print("PASS radial sampling stays continuous, monotonic and bounded (ramp shift \(largestShift))")
        var rimShifts = [Int]()
        for diameter: CGFloat in [260, 780] {
            for scale: CGFloat in [1, 2, 3] {
                let shift = autoreleasepool { () -> Int in
                    func scaledRamp(_ refracts: Bool) -> CGImage {
                        LoupeRenderer.shared.render(preview: rampPreview, point: CGPoint(x: 300, y: 300),
                            imageSize: CGSize(width: 600, height: 600), diameter: diameter,
                            magnification: 2.5 * diameter / 260, displayScale: scale,
                            transmission: 1, flare: 0, brightness: 1, refracts: refracts)!
                    }
                    let plain = pixels(scaledRamp(false)), bent = pixels(scaledRamp(true))
                    let width = Int(diameter * scale), radius = width / 2
                    // Subpixel movement can quantize to zero at one 8-bit
                    // sample. Compare the rim band at every display scale.
                    return (Int(Double(radius) * 1.90)..<Int(Double(radius) * 1.995)).map { x in
                        let i = (radius * width + x) * 4
                        return abs(Int(plain[i]) - Int(bent[i]))
                    }.max() ?? 0
                }
                precondition(shift >= 1 && shift <= 5, "glass curvature sample shift \(shift) at diameter \(diameter), scale \(scale)")
                rimShifts.append(shift)
            }
        }
        precondition(rimShifts.max()! - rimShifts.min()! <= 2, "approaching or Retina scale changes lens curvature")
        print("PASS normal and close lenses retain restrained curvature at 1x, 2x and 3x display scales")
        func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PhotoPreview {
            context.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let image = context.makeImage()!
            return PhotoPreview(source: image, lit: image, dark: image, flare: image)
        }
        let red = solid(0.9, 0.05, 0.05), blue = solid(0.05, 0.05, 0.9)
        let cropPhotos = [
            LoupeScenePhoto(preview: blue, center: CGPoint(x: 300, y: 300), imageSize: CGSize(width: 2000, height: 2000)),
            LoupeScenePhoto(preview: red, center: CGPoint(x: 660.5, y: 300), imageSize: CGSize(width: 2, height: 100))
        ]
        for scale: CGFloat in [1, 2] {
            for strength: CGFloat in [0.45, 1] {
                let region = CGRect(x: 755, y: 376, width: 25, height: 28)
                func cropRender(_ viewport: CGRect?) -> CGImage {
                    LoupeRenderer.shared.render(photos: cropPhotos, point: CGPoint(x: 300, y: 300),
                        diameter: 780, magnification: 1, displayScale: scale, transmission: 1,
                        flare: 0, brightness: 1, viewport: viewport, refractionScale: strength)!
                }
                let full = cropRender(nil)
                let expected = pixels(full.cropping(to: CGRect(x: region.minX * scale, y: region.minY * scale,
                    width: region.width * scale, height: region.height * scale))!)
                let actual = pixels(cropRender(region))
                precondition(actual.count == expected.count)
                let difference = zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                precondition(Double(difference) / Double(actual.count) < 1,
                    "cropped optical viewport lost source content or changed orientation")
                if strength == 1 {
                    precondition(stride(from: 0, to: actual.count, by: 4).contains {
                        actual[$0] > 150 && actual[$0 + 2] < 100
                    }, "cropped refraction did not include the film beyond the unwarped crop")
                }
            }
        }
        print("PASS cropped viewport matches the full lens and includes inward-refracted neighboring films")
        let left = LoupeScenePhoto(preview: red, center: CGPoint(x: 90, y: 150), imageSize: CGSize(width: 80, height: 180))
        let right = LoupeScenePhoto(preview: blue, center: CGPoint(x: 210, y: 150), imageSize: CGSize(width: 80, height: 180))
        func scene(_ photos: [LoupeScenePhoto], point: CGPoint = CGPoint(x: 150, y: 150), panel: CGRect? = nil) -> [UInt8] {
            pixels(LoupeRenderer.shared.render(photos: photos, point: point, panelBounds: panel,
                diameter: 260, magnification: 2.5, displayScale: 2, transmission: 1, flare: 0, brightness: 1)!)
        }
        func rgb(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [Int] {
            let i = (y * 520 + x) * 4
            return (0..<3).map { Int(bytes[i + $0]) }
        }
        func isRed(_ value: [Int]) -> Bool { value[0] > 150 && value[1] < 70 && value[2] < 70 }
        func isBlue(_ value: [Int]) -> Bool { value[2] > 150 && value[0] < 70 && value[1] < 70 }
        let gap = scene([left, right])
        precondition(isRed(rgb(gap, 60, 260)) && isBlue(rgb(gap, 460, 260)), "blank-centred lens missed neighboring films")
        precondition(rgb(gap, 260, 260).allSatisfy { $0 > 180 }, "blank gap was replaced by a photo")
        precondition(rgb(gap, 175, 260).allSatisfy { $0 > 180 }, "an extra film frame obscures the tabletop")
        print("PASS blank-centred lens includes both neighboring films and the gap without extra frames")
        let lower = LoupeScenePhoto(preview: red, center: CGPoint(x: 150, y: 150), imageSize: CGSize(width: 180, height: 180))
        let upper = LoupeScenePhoto(preview: blue, center: CGPoint(x: 150, y: 150), imageSize: CGSize(width: 40, height: 80))
        let overlap = scene([lower, upper])
        precondition(isBlue(rgb(overlap, 260, 260)) && isRed(rgb(overlap, 60, 260)), "overlap did not preserve visible order")
        precondition(isRed(rgb(overlap, 375, 260)), "an extra film frame obscures the lower image")
        precondition(isRed(rgb(scene([upper, lower]), 260, 260)), "render order was ignored")
        print("PASS overlapping films follow source edges and table stacking exactly")
        let rotated = LoupeScenePhoto(preview: blue, center: CGPoint(x: 150, y: 150), imageSize: CGSize(width: 120, height: 40), angle: 90)
        let turned = scene([rotated])
        precondition(isBlue(rgb(turned, 260, 60)), "rotated film was not vertical")
        precondition(rgb(turned, 60, 260).allSatisfy { $0 > 180 }, "unrotated footprint leaked through")
        print("PASS scene lens follows rotated film geometry")
        let empty = scene([])
        precondition(rgb(empty, 260, 260).allSatisfy { $0 > 180 }, "empty table failed to render")
        let boardEdge = scene([], point: CGPoint(x: 0, y: 150), panel: CGRect(x: 0, y: 0, width: 300, height: 300))
        precondition(rgb(boardEdge, 60, 260).allSatisfy { $0 < 40 } && rgb(boardEdge, 460, 260).allSatisfy { $0 > 180 }, "table boundary was not respected")
        print("PASS empty tabletop and outer black area render without a selected photo")
        let fallback = LoupeScenePhoto(preview: nil, thumbnail: red.source, center: CGPoint(x: 150, y: 150), imageSize: CGSize(width: 120, height: 120))
        precondition(isRed(rgb(scene([fallback]), 260, 260)), "thumbnail fallback disappeared from lens")
        print("PASS lens retains thumbnail content while high-resolution preview loads")

        // Four-source-pixel stripes disappear if a 2400px image is reduced to
        // 120 table points before the lens magnifies it. Equal final scales
        // must retain the same detail, independent of table size.
        let detailContext = CGContext(data: nil, width: 2400, height: 1800, bitsPerComponent: 8,
            bytesPerRow: 2400 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<2400 {
            detailContext.setFillColor(CGColor(gray: (x / 4).isMultiple(of: 2) ? 0.1 : 0.9, alpha: 1))
            detailContext.fill(CGRect(x: x, y: 0, width: 1, height: 1800))
        }
        let detail = detailContext.makeImage()!
        let detailPreview = PhotoPreview(source: detail, lit: detail, dark: detail, flare: detail)
        func detailRender(width: CGFloat, magnification: CGFloat, scale: CGFloat,
                          angle: Double = 0, refracts: Bool) -> CGImage {
            let size = CGSize(width: width, height: width * 0.75)
            let photo = LoupeScenePhoto(preview: detailPreview,
                center: CGPoint(x: size.width / 2, y: size.height / 2), imageSize: size, angle: angle)
            return LoupeRenderer.shared.render(photos: [photo],
                point: CGPoint(x: size.width * 0.52, y: size.height * 0.48),
                diameter: 260, magnification: magnification, displayScale: scale,
                transmission: 1, flare: 0, brightness: 1, refracts: refracts)!
        }
        func assertSameDetail(_ small: CGImage, _ large: CGImage) {
            precondition(small.width == large.width && small.height == large.height)
            let a = pixels(small), b = pixels(large), width = small.width
            var difference = 0.0, detailEnergy = 0.0, count = 0.0
            for y in (width * 3 / 8)..<(width * 5 / 8) {
                for x in (width * 3 / 8)..<(width * 5 / 8) {
                    let i = (y * width + x) * 4
                    difference += abs(Double(a[i]) - Double(b[i]))
                    detailEnergy += abs(Double(a[i]) - Double(a[i - 4]))
                    count += 1
                }
            }
            precondition(difference / count < 1, "table size changed lens sharpness: \(difference / count)")
            precondition(detailEnergy / count > 20, "source detail was downsampled away: \(detailEnergy / count)")
        }
        for refracts in [false, true] {
            assertSameDetail(
                detailRender(width: 120, magnification: 2.5, scale: 2, refracts: refracts),
                detailRender(width: 300, magnification: 1, scale: 2, refracts: refracts))
            print("PASS small table photos retain source detail with refraction \(refracts)")
        }
        for scale: CGFloat in [1, 2, 3] {
            assertSameDetail(
                detailRender(width: 120, magnification: 5, scale: scale, angle: 27, refracts: true),
                detailRender(width: 600, magnification: 1, scale: scale, angle: 27, refracts: true))
        }
        print("PASS rotated, off-centre photos retain detail at 1x, 2x and 3x display scales")
        assertSameDetail(
            detailRender(width: 120, magnification: 10, scale: 2, refracts: true),
            detailRender(width: 600, magnification: 2, scale: 2, refracts: true))
        print("PASS high magnification resolves original source pixels without enlarging table photos")
        let midtone = solid(0.4, 0.4, 0.4), blackHalo = solid(0, 0, 0), bright = solid(0.7, 0.7, 0.7)
        let stablePreview = PhotoPreview(source: midtone.source, lit: midtone.lit, dark: midtone.dark,
            flare: blackHalo.source, boosted: bright.source)
        func illuminated(_ flare: Double, _ brightness: Double) -> [UInt8] {
            pixels(LoupeRenderer.shared.render(preview: stablePreview, point: CGPoint(x: 300, y: 300),
                imageSize: CGSize(width: 600, height: 600), diameter: 260, magnification: 2.5,
                displayScale: 2, transmission: 1, flare: flare, brightness: brightness)!)
        }
        for power in [0.1, 1.0, 1.6] {
            let base = illuminated(0, power), peak = illuminated(1, power)
            let center = (260 * 520 + 260) * 4
            precondition(peak[center] > base[center], "lens does not share ignition overexposure")
        }
        let centerPixel = (260 * 520 + 260) * 4
        precondition(Int(illuminated(0, 1.6)[centerPixel]) > Int(illuminated(0, 1)[centerPixel]) + 20,
            "steady brightness no longer responds to the slider")
        print("PASS lens shares ignition exposure and retains steady brightness slider response")
        print("RESULT 19 passed; 0 failed")
    }
}
