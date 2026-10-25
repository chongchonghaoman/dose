import SwiftUI

/// Two discrete magnifications with a single sliding thumb.
struct LoupeMagnificationControl: View {
    @Binding var selection: LoupeCloseMagnification
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var draggedOffset: CGFloat?

    private let segmentWidth: CGFloat = 54
    private let spacing: CGFloat = 2
    private var travel: CGFloat { segmentWidth + spacing }
    private var selectedOffset: CGFloat { selection == .original ? 0 : travel }

    var body: some View {
        let thumbOffset = draggedOffset ?? selectedOffset
        ZStack(alignment: .leading) {
            Capsule().fill(.white)
                .frame(width: segmentWidth, height: 30)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                .offset(x: thumbOffset)
                // Follow the hand directly; animate only clicks and release.
                .animation(reduceMotion || draggedOffset != nil ? nil : .easeOut(duration: 0.20), value: thumbOffset)
                .allowsHitTesting(false)
            HStack(spacing: spacing) {
                ForEach(LoupeCloseMagnification.allCases, id: \.self) { mode in
                    Button { selection = mode } label: {
                        Text(mode.title)
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .frame(width: segmentWidth, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("大放大镜：\(mode.title)")
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                }
            }
        }
        .contentShape(Capsule())
        .highPriorityGesture(DragGesture(minimumDistance: 3)
            .updating($draggedOffset) { value, offset, transaction in
                transaction.animation = nil
                offset = min(travel, max(0, selectedOffset + value.translation.width))
            }
            .onEnded { value in
                let destination = selectedOffset + value.translation.width
                selection = destination < travel / 2 ? .original : .eight
            })
    }
}
