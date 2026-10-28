import AppKit
import SwiftUI

struct SleeveFlight {
    enum Phase { case dragging, landing, returning }
    let id = UUID()
    let photo: Photo
    let thumbnail: CGImage
    let sleeve: CGRect
    let origin: CGRect
    let start: CGPoint
    var frame: CGRect
    var expansion: CGFloat = 0
    var lift: CGFloat = 0
    var angle: Double = 0
    var phase = Phase.dragging
}

struct SleeveFlightView: View {
    let flight: SleeveFlight
    let preview: PhotoPreview?
    let isLit: Bool
    let brightness: Double
    let edrEnabled: Bool
    let reduceMotion: Bool

    var body: some View {
        let inset = flight.expansion
        let available = flight.frame.size
        let aspect = CGFloat(flight.thumbnail.width) / CGFloat(flight.thumbnail.height)
        let imageWidth = min(available.width, available.height * aspect)
        let imageSize = CGSize(width: imageWidth, height: imageWidth / aspect)
        ZStack {
            Color.clear
            Image(decorative: flight.thumbnail, scale: 1).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .colorMultiply(Color(white: isLit ? 1 : 1 - 0.90 * Double(inset)))
                .frame(width: imageSize.width, height: imageSize.height)
            if let preview {
                TransmittedPhoto(preview: preview, size: imageSize, transmission: isLit ? 1 : 0,
                                 flare: 0, brightness: brightness, edrEnabled: edrEnabled)
                    .opacity(Double(inset))
            }
        }
        .frame(width: flight.frame.width, height: flight.frame.height)
        .shadow(color: .black.opacity(0.18 + 0.17 * flight.lift),
                radius: 2 + 6 * flight.lift, x: 1 + 2 * flight.lift, y: 2 + 8 * flight.lift)
        .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(flight.lift) * 5), axis: (x: 1, y: 0, z: 0), perspective: 0.15)
        .rotationEffect(.degrees(flight.angle))
        .position(x: flight.frame.midX, y: flight.frame.midY)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WorkbenchFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
