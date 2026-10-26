import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct ReturnToPastPreparedImage: Sendable {
    let inputURL: URL
    /// Fraction of the oriented source image, with its origin at the top left.
    let aperture: CGRect
}

enum ReturnToPastImage {
    private static let fullImage = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func prepare(source: URL, directory: URL) throws -> ReturnToPastPreparedImage {
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageError("无法读取这张照片")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let context = CIContext(options: [.cacheIntermediates: false])
        let image: CGImage
        if isRAW(source, imageSource: imageSource) {
            guard let raw = CIRAWFilter(imageURL: source) else { throw ImageError("系统无法解码这张 RAW 照片") }
            let nativeSize = raw.nativeSize
            guard nativeSize.width.isFinite, nativeSize.height.isFinite,
                  nativeSize.width > 0, nativeSize.height > 0 else { throw ImageError("RAW 照片尺寸无效") }
            raw.scaleFactor = min(1, 2048 / Float(max(nativeSize.width, nativeSize.height)))
            guard let output = raw.outputImage,
                  let decoded = context.createCGImage(output, from: output.extent,
                    format: .RGBA8, colorSpace: srgb) else { throw ImageError("RAW 照片解码失败") }
            guard isValidRAWDecode(nativeSize: nativeSize,
                decodedSize: CGSize(width: decoded.width, height: decoded.height),
                scaleFactor: raw.scaleFactor) else { throw ImageError("RAW 照片解码尺寸异常") }
            image = decoded
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
                  let decoded = context.createCGImage(CIImage(cgImage: thumbnail),
                    from: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height),
                    format: .RGBA8, colorSpace: srgb) else { throw ImageError("照片解码失败") }
            image = decoded
        }
        try Task.checkCancellation()
        let detected = aperture(in: image)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let crop = CGRect(x: detected.minX * bounds.width, y: detected.minY * bounds.height,
            width: detected.width * bounds.width, height: detected.height * bounds.height)
            .integral.intersection(bounds)
        guard let cropped = image.cropping(to: crop) else { throw ImageError("无法准备照片画面") }
        let aperture = CGRect(x: crop.minX / bounds.width, y: crop.minY / bounds.height,
            width: crop.width / bounds.width, height: crop.height / bounds.height)

        let retainedKeys = Set(["FocalLength", "FocalLenIn35mmFilm", "FocalLengthIn35mmFilm",
            "FNumber", "ExposureTime", "ISOSpeedRatings"])
        var selectedExif = exif.filter { retainedKeys.contains($0.key) }
        if aperture != fullImage {
            // Cropping leaves focal length in pixels unchanged. Encode the
            // equivalent 35 mm focal length for SHARP's diagonal-based reader.
            let focal = (exif["FocalLenIn35mmFilm"] as? NSNumber)?.doubleValue
                ?? (exif["FocalLengthIn35mmFilm"] as? NSNumber)?.doubleValue
                ?? (exif["FocalLength"] as? NSNumber)?.doubleValue ?? 30
            let scale = hypot(bounds.width, bounds.height) / hypot(crop.width, crop.height)
            // EXIF stores this value as a 16-bit integer; ImageIO drops a
            // floating-point value instead of writing it to the JPEG.
            selectedExif["FocalLenIn35mmFilm"] = Int(min(65535, max(1, focal * scale)).rounded())
            selectedExif.removeValue(forKey: "FocalLengthIn35mmFilm")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("input.jpg")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError("无法写入临时照片")
        }
        CGImageDestinationAddImage(destination, cropped, [
            kCGImagePropertyExifDictionary: selectedExif,
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.98
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError("临时照片保存失败") }
        try Task.checkCancellation()
        return ReturnToPastPreparedImage(inputURL: output, aperture: aperture)
    }

    static func isValidRAWDecode(nativeSize: CGSize, decodedSize: CGSize, scaleFactor: Float) -> Bool {
        let nativeSides = [nativeSize.width, nativeSize.height].sorted()
        let decodedSides = [decodedSize.width, decodedSize.height].sorted()
        guard scaleFactor.isFinite, scaleFactor > 0,
              nativeSides.allSatisfy({ $0.isFinite && $0 > 0 }),
              decodedSides.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }
        // Compare without orientation: a RAW's embedded preview must never
        // satisfy the expected dimensions of its requested sensor decode.
        return zip(nativeSides, decodedSides).allSatisfy { native, decoded in
            decoded >= native * Double(scaleFactor) * 0.90
        }
    }

    /// Detect only a recognisable perforated black film frame. Plain dark
    /// borders and uncertain photographs deliberately keep their whole image.
    static func aperture(in image: CGImage) -> CGRect {
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard width >= 64, height >= 64,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return fullImage }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return fullImage }
        let sample = FrameSample(width: width, height: height, pixels: pixels)
        if let rectangle = sample.photographicRectangle(transposed: false) { return rectangle }
        if let rectangle = sample.photographicRectangle(transposed: true) {
            return CGRect(x: rectangle.minY, y: rectangle.minX,
                width: rectangle.height, height: rectangle.width)
        }
        return fullImage
    }

    private static func isRAW(_ url: URL, imageSource: CGImageSource) -> Bool {
        if let identifier = CGImageSourceGetType(imageSource),
           let type = UTType(identifier as String), type.conforms(to: .rawImage) { return true }
        return Set(["dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
            "rw2", "pef", "ptx", "rwl", "3fr", "fff", "iiq", "kdc", "dcr", "mos", "mrw", "raw", "x3f"])
            .contains(url.pathExtension.lowercased())
    }

    private struct ImageError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct FrameSample {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        func photographicRectangle(transposed: Bool) -> CGRect? {
            let w = transposed ? height : width
            let h = transposed ? width : height
            func brightness(_ x: Int, _ y: Int) -> Int {
                let index = ((transposed ? x : y) * width + (transposed ? y : x)) * 4
                return max(Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
            }
            func rowFraction(_ y: Int, _ xs: Range<Int>, brighterThan threshold: Int) -> Double {
                Double(xs.reduce(0) { $0 + (brightness($1, y) > threshold ? 1 : 0) }) / Double(xs.count)
            }
            func hasPerforations(_ y: Int) -> Bool {
                var runs = [Range<Int>]()
                var start: Int?
                var dark = 0
                for x in 0..<w {
                    let value = brightness(x, y)
                    if value < 45 { dark += 1 }
                    if value > 190 {
                        if start == nil { start = x }
                    } else if let lower = start {
                        runs.append(lower..<x); start = nil
                    }
                }
                if let lower = start { runs.append(lower..<w) }
                let holes = runs.filter { $0.count >= 2 && $0.count <= max(3, w / 9) }
                guard holes.count >= 4, Double(dark) / Double(w) > 0.40,
                      let first = holes.first, let last = holes.last,
                      last.upperBound - first.lowerBound > w / 2 else { return false }
                let widths = holes.map(\.count).sorted()
                let median = widths[widths.count / 2]
                return holes.filter { abs($0.count - median) <= max(2, median / 2) }.count >= 4
            }
            let margin = max(4, h / 4)
            guard let topHoles = (1..<margin).first(where: hasPerforations),
                  let bottomHoles = ((h - margin)..<(h - 1)).reversed().first(where: hasPerforations) else { return nil }
            let middle = (w / 10)..<(w - w / 10)
            guard let topGap = ((topHoles + 1)..<(h / 3)).first(where: {
                rowFraction($0, middle, brighterThan: 40) < 0.12
            }), let bottomGap = ((h * 2 / 3)..<bottomHoles).reversed().first(where: {
                rowFraction($0, middle, brighterThan: 40) < 0.12
            }), let top = ((topGap + 1)..<(h / 3)).first(where: {
                rowFraction($0, middle, brighterThan: 30) > 0.50
            }), let bottom = ((h * 2 / 3)..<bottomGap).reversed().first(where: {
                rowFraction($0, middle, brighterThan: 30) > 0.50
            }), bottom - top > h / 2 else { return nil }

            let innerY = (top + (bottom - top) / 10)..<(bottom - (bottom - top) / 10)
            func columnFraction(_ x: Int) -> Double {
                Double(innerY.reduce(0) { $0 + (brightness(x, $1) > 30 ? 1 : 0) }) / Double(innerY.count)
            }
            guard let left = (0..<(w / 5)).first(where: { columnFraction($0) > 0.50 }),
                  let right = ((w * 4 / 5)..<w).reversed().first(where: { columnFraction($0) > 0.50 }),
                  left > 0, right < w - 1, right - left > w * 3 / 4 else { return nil }
            let gapTopDark = rowFraction(max(0, top - 1), left..<(right + 1), brighterThan: 40) < 0.20
            let gapBottomDark = rowFraction(min(h - 1, bottom + 1), left..<(right + 1), brighterThan: 40) < 0.20
            guard gapTopDark && gapBottomDark else { return nil }
            return CGRect(x: Double(left) / Double(w), y: Double(top) / Double(h),
                width: Double(right - left + 1) / Double(w), height: Double(bottom - top + 1) / Double(h))
        }
    }
}
