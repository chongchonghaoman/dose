import SwiftUI

/// Keeps the animation clock inside the control, away from photo rendering.
struct BacklightEDRButton: View {
    @Binding var isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button { isOn.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                Label("背光 EDR", systemImage: isOn ? "sun.max.fill" : "sun.max")
                    .frame(width: 112)
                Image(systemName: isOn ? "sun.max.fill" : "sun.max")
                    .frame(width: 38)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color(white: 0.30))
            .frame(minWidth: 38, idealWidth: 112, maxWidth: 112)
            .frame(height: 38)
            .background {
                background
                    .brightness(hovered && isEnabled ? 0.018 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
            }
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isOn)
        }
        .buttonStyle(ReturnToPastEntryButtonStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel("背光 EDR")
        .accessibilityValue(isOn ? "开，亮度固定 120%" : "关，亮度可调")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help("背光 + EDR：\(isOn ? "开，亮度固定 120%" : "关，可调整右侧亮度")；按 E 切换，按住空格凑近时也可用")
    }

    private var background: some View {
        ZStack {
            Capsule().fill(Color(white: 0.92))
            TimelineView(.animation(minimumInterval: 1.0 / 30,
                                    paused: !isOn || reduceMotion || scenePhase != .active || !isEnabled)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.36, green: 0.16, blue: 0.055),
                                 Color(red: 0.48, green: 0.22, blue: 0.065),
                                 Color(red: 0.44, green: 0.13, blue: 0.085)],
                        startPoint: .leading, endPoint: .trailing)
                    Canvas { context, size in
                        let bounds = Path(CGRect(origin: .zero, size: size))
                        let gold = CGPoint(x: size.width * (0.34 + 0.22 * sin(time * 0.38)),
                                           y: size.height * 0.08)
                        context.fill(bounds, with: .radialGradient(
                            Gradient(colors: [Color(red: 0.98, green: 0.65, blue: 0.22).opacity(0.28), .clear]),
                            center: gold, startRadius: 0, endRadius: size.width * 0.72))
                        let coral = CGPoint(x: size.width * (0.76 + 0.18 * sin(time * 0.29 + 1.6)),
                                            y: size.height * 0.94)
                        context.fill(bounds, with: .radialGradient(
                            Gradient(colors: [Color(red: 0.94, green: 0.34, blue: 0.19).opacity(0.18), .clear]),
                            center: coral, startRadius: 0, endRadius: size.width * 0.58))

                        // Small glints stay along the edges, clear of the label.
                        for index in 0..<8 {
                            let seed = Double(index)
                            let cycle = (seed * 0.61803398875 + time * 0.018)
                                .truncatingRemainder(dividingBy: 1)
                            let x = cycle * size.width
                            let y = size.height * (index.isMultiple(of: 2) ? 0.15 : 0.85)
                                + sin(time * 0.65 + seed) * 1.2
                            let radius = index.isMultiple(of: 3) ? 0.85 : 0.55
                            let edgeFade = min(1, min(cycle, 1 - cycle) * 12)
                            let shimmer = 0.16 + 0.12 * (sin(time * 0.9 + seed * 1.7) + 1) / 2
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                                         with: .color(Color(red: 1, green: 0.88, blue: 0.57)
                                            .opacity(shimmer * edgeFade)))
                        }
                    }
                }
            }
            .opacity(isOn ? 1 : 0)
        }
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(
                LinearGradient(colors: [.white.opacity(isOn ? 0.22 : 0.45),
                                        .black.opacity(isOn ? 0.14 : 0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.7)
        }
    }
}
