import SwiftUI

/// Adjacent sleeves share a welded edge, forming one continuous archival strip.
struct FilmSleeve: View {
    let image: CGImage?
    var failed = false
    var onTable = false
    var highlighted = false
    var lifted = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.16), location: 0),
                    .init(color: .white.opacity(0.055), location: 0.18),
                    .init(color: .white.opacity(0.08), location: 0.8),
                    .init(color: .white.opacity(0.13), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))

            ZStack {
                Color.clear
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.75))
                }
            }
            .frame(width: 90, height: 56)
            .clipped()
            .opacity(lifted ? 0 : 1)
            .padding(.horizontal, 7).padding(.top, 9).padding(.bottom, 5)

            // The clear front sheet sits over the photograph, including its margins.
            FilmSleeveSurface().opacity(lifted ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)

            if onTable && !lifted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.white, .black).padding(9)
            }
        }
        .frame(width: 104, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

}

struct FilmSleeveSurface: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height

            func line(_ points: [CGPoint], color: Color, width: CGFloat = 0.5) {
                var path = Path()
                path.addLines(points)
                context.stroke(path, with: .color(color), lineWidth: width)
            }

            // Paired highlights and shadows read as heat welds, rather than card borders.
            for x in [CGFloat(0.75), w - 3.25] {
                line([CGPoint(x: x, y: 1), CGPoint(x: x, y: h - 1)], color: .white.opacity(0.28))
                line([CGPoint(x: x + 1, y: 1), CGPoint(x: x + 1, y: h - 1)], color: .black.opacity(0.55), width: 1)
                line([CGPoint(x: x + 2, y: 1), CGPoint(x: x + 2, y: h - 1)], color: .white.opacity(0.1))
            }
            line([CGPoint(x: 3, y: 0.75), CGPoint(x: w - 3, y: 0.75)], color: .white.opacity(0.36))
            line([CGPoint(x: 4, y: 6.5), CGPoint(x: w - 4, y: 6.5)], color: .white.opacity(0.23))
            line([CGPoint(x: 4, y: 7.5), CGPoint(x: w - 4, y: 7.5)], color: .black.opacity(0.5), width: 1)
            line([CGPoint(x: 3, y: h - 2), CGPoint(x: w - 3, y: h - 2)], color: .white.opacity(0.24))
            line([CGPoint(x: 4, y: h - 4), CGPoint(x: w - 4, y: h - 4)], color: .black.opacity(0.35))

            var sheen = Path()
            sheen.move(to: CGPoint(x: 4, y: 9))
            sheen.addLine(to: CGPoint(x: w * 0.23, y: 9))
            sheen.addLine(to: CGPoint(x: w * 0.65, y: h - 5))
            sheen.addLine(to: CGPoint(x: w * 0.4, y: h - 5))
            sheen.closeSubpath()
            context.fill(sheen, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.09), .white.opacity(0.015)]),
                startPoint: CGPoint(x: 0, y: 9), endPoint: CGPoint(x: w * 0.65, y: h)))

            var lip = Path()
            lip.move(to: CGPoint(x: 5, y: 5))
            lip.addQuadCurve(to: CGPoint(x: w - 5, y: 4), control: CGPoint(x: w * 0.6, y: 1.5))
            context.stroke(lip, with: .color(.white.opacity(0.22)), lineWidth: 0.6)

            for x in [CGFloat(5), w - 5] {
                let direction: CGFloat = x < w / 2 ? 1 : -1
                var fold = Path()
                fold.move(to: CGPoint(x: x, y: h - 4))
                fold.addQuadCurve(to: CGPoint(x: x + direction * 7, y: h - 12),
                                  control: CGPoint(x: x + direction * 2, y: h - 6))
                context.stroke(fold, with: .color(.white.opacity(0.13)), lineWidth: 0.5)
            }
        }
    }
}
