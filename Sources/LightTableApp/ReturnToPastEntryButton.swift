import SwiftUI

/// A small, self-contained animation: its clock never updates the canvas or player.
struct ReturnToPastEntryLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: reduceMotion || scenePhase != .active || !isEnabled)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    Capsule().fill(LinearGradient(
                        colors: [Color(red: 0.12, green: 0.25, blue: 0.82),
                                 Color(red: 0.40, green: 0.23, blue: 0.87),
                                 Color(red: 0.60, green: 0.33, blue: 0.96)],
                        startPoint: .leading, endPoint: .trailing))
                    Canvas { context, size in
                        let glowX = size.width * (0.52 + 0.17 * sin(time * 0.38))
                        let center = CGPoint(x: glowX, y: size.height * 0.32)
                        context.fill(Path(ellipseIn: CGRect(x: glowX - 66, y: -31, width: 132, height: 92)),
                                     with: .radialGradient(Gradient(colors: [.white.opacity(0.24), .white.opacity(0)]),
                                                           center: center, startRadius: 0, endRadius: 66))
                        for index in 0..<20 {
                            let seed = Double(index)
                            let cycle = (seed * 0.61803398875 + time * (0.018 + Double(index % 3) * 0.004))
                                .truncatingRemainder(dividingBy: 1)
                            let x = cycle * size.width
                            let y = size.height * (0.20 + Double((index * 7) % 13) / 20)
                                + sin(time * 0.7 + seed * 1.9) * 2
                            let radius = index % 6 == 0 ? 1.25 : 0.7
                            let edgeFade = min(1, min(cycle, 1 - cycle) * 12)
                            let shimmer = 0.34 + 0.28 * (sin(time * 1.2 + seed * 2.1) + 1) / 2
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                                         with: .color(.white.opacity(shimmer * edgeFade)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            Text("回到过去")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
        }
        .frame(width: 138, height: 38)
        .brightness(hovered && isEnabled ? 0.045 : 0)
        .contentShape(Capsule())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }
}

struct ReturnToPastEntryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
