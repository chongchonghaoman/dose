import CoreGraphics
import Foundation
import SwiftUI

/// A single small texture for every loose film. Only the edge strips stretch;
/// no photo pixels, blur filters, per-photo bitmaps or animation clocks are used.
enum FilmContactTexture {
    static let scale: CGFloat = 3
    static let side: CGFloat = 32
    static let padding: CGFloat = 4
    static let cap: CGFloat = 8

    static let image: CGImage? = {
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
                let dx = max(lower + 0.35 - x, 0, x - upper - 0.35)
                let dy = max(lower + 0.8 - y, 0, y - upper - 0.8)
                let falloff = max(0, 1 - hypot(dx, dy) / 1.5)
                var alpha = 0.28 * falloff * falloff
                var white: CGFloat = 0
                // Less than one point of exposed substrate on the lower/right
                // edge: thin film, not a raised photo frame.
                if x >= lower + 0.35 && x < upper + 0.6 &&
                    y >= lower + 0.5 && y < upper + 0.85 {
                    alpha = 0.78
                    white = y >= upper ? 0.055 : 0.11
                }
                // A faint grazing edge on the light-facing side, outside the image.
                if x >= lower - 0.2 && x < upper &&
                    y >= lower - 0.2 && y < upper {
                    alpha = 0.14
                    white = 1
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
    }()
}

struct FilmContactSurface: View, Equatable {
    let size: CGSize
    let zoom: CGFloat

    var body: some View {
        if let image = FilmContactTexture.image {
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
