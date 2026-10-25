import SwiftUI

/// Incoming slides follow the upper arc from the left; outgoing slides are
/// kicked left with a quick tilt before the shutter closes for the black gap.
struct ProjectionTravelPose {
    let x: CGFloat
    let y: CGFloat
    let angle: Double

    static func at(_ transport: Double, container: CGSize, image: CGSize) -> Self {
        let distance = (container.width + image.width) * 0.52
        if transport > 0 {
            let progress = min(1, transport)
            return Self(x: -(distance + image.height * 0.07) * progress,
                        y: container.height * 0.025 * progress,
                        angle: 8 * progress)
        }
        let progress = min(1, max(0, -transport))
        return Self(x: -distance * progress,
                    y: -container.height * (0.15 * sin(.pi * progress) + 0.035 * progress),
                    angle: -5 * progress)
    }
}

struct ProjectionTravel: AnimatableModifier {
    var progress: Double
    let container: CGSize
    let image: CGSize
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = ProjectionTravelPose.at(progress, container: container, image: image)
        content.rotationEffect(.degrees(pose.angle)).offset(x: pose.x, y: pose.y)
    }
}
