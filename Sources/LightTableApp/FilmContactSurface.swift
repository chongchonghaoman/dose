import CoreGraphics
import Foundation
import SwiftUI

enum FilmContactVariant: Int, CaseIterable {
    case settled, leftCurl, rightCurl

    /// Unlike Hasher, this mapping stays fixed across launches for a saved film.
    static func forFilm(_ id: UUID) -> Self {
        let hash = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        return Self(rawValue: Int(hash % 3))!
    }
}

/// Three small textures shared by all loose films. Only the edge strips stretch;
/// no photo pixels, blur filters, per-photo bitmaps or animation clocks are used.
enum FilmContactTexture {
    static let scale: CGFloat = 3
    static let side: CGFloat = 32
    static let padding: CGFloat = 4
    static let cap: CGFloat = 12
    private static let images = FilmContactVariant.allCases.map(makeImage)

    static func image(for variant: FilmContactVariant) -> CGImage? { images[variant.rawValue] }

    private static func makeImage(_ variant: FilmContactVariant) -> CGImage? {
        let pixels = Int(side * scale)
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let lower = padding, upper = side - padding
        for row in 0..<pixels {
            for column in 0..<pixels {
                let x = (CGFloat(column) + 0.5) / scale
                let y = (CGFloat(row) + 0.5) / scale
                // Leave the entire photograph rectangle transparent. Decoration
                // lives outside it and cannot crop or tint the source image.
                if x >= lower && x < upper && y >= lower && y < upper { continue }
                // Curl differences end inside the fixed corner caps, so a
                // larger photo cannot stretch a lifted corner into a long halo.
                let cornerX = variant == .leftCurl ? lower : upper
                let corner = max(0, 1 - hypot(x - cornerX, y - upper) / (cap - padding))
                let lift: CGFloat = variant == .settled ? 0 : corner * corner * 0.72
                let offsetX: CGFloat = 0.28
                let offsetY = 0.58 + lift * 0.72
                let dx = max(lower + offsetX - x, 0, x - upper - offsetX)
                let dy = max(lower + offsetY - y, 0, y - upper - offsetY)
                let falloff = max(0, 1 - hypot(dx, dy) / (1.35 + lift * 0.75))
                var alpha = (0.27 - lift * 0.07) * falloff * falloff
                var white: CGFloat = 0
                // Less than one point of exposed substrate on the lower/right
                // edge: thin film, not a raised photo frame.
                let alongX = min(1, max(0, (x - lower) / (upper - lower)))
                let alongY = min(1, max(0, (y - lower) / (upper - lower)))
                let right = 0.40 + alongY * 0.14 + lift * 0.12
                let bottom = 0.50 + alongX * 0.22 + lift * 0.16
                let rightCoverage = min(1, max(0, (upper + right - x) * scale))
                let bottomCoverage = min(1, max(0, (upper + bottom - y) * scale))
                if x >= lower + 0.28 && x < upper + right &&
                    y >= lower + 0.38 && y < upper + bottom {
                    let sideAlpha = (0.74 - lift * 0.08) * min(rightCoverage, bottomCoverage)
                    let sideWhite: CGFloat = y >= upper ? 0.065 : 0.13
                    let combined = sideAlpha + alpha * (1 - sideAlpha)
                    white = combined > 0 ? sideWhite * sideAlpha / combined : 0
                    alpha = combined
                }
                // A faint grazing edge on the light-facing side, outside the image.
                if x >= lower - 0.24 && x < upper &&
                    y >= lower - 0.24 && y < upper {
                    let edgeAlpha = y < lower ? 0.18 - alongX * 0.07 : 0.12 - alongY * 0.04
                    let combined = edgeAlpha + alpha * (1 - edgeAlpha)
                    white = (edgeAlpha + white * alpha * (1 - edgeAlpha)) / combined
                    alpha = combined
                }
                let index = (row * pixels + column) * 4
                let value = UInt8((white * alpha * 255).rounded())
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                bytes[index + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: pixels * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct FilmContactSurface: View, Equatable {
    let size: CGSize
    let zoom: CGFloat
    let variant: FilmContactVariant

    var body: some View {
        if let image = FilmContactTexture.image(for: variant) {
            let scale = max(0.01, zoom)
            let cap = FilmContactTexture.cap
            Image(decorative: image, scale: FilmContactTexture.scale)
                .resizable(capInsets: EdgeInsets(top: cap, leading: cap, bottom: cap, trailing: cap),
                           resizingMode: .stretch)
                .interpolation(.high)
                .frame(width: size.width / scale + 2 * FilmContactTexture.padding,
                       height: size.height / scale + 2 * FilmContactTexture.padding)
                .scaleEffect(scale)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
