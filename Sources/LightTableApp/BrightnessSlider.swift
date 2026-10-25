import AppKit
import SwiftUI

struct BrightnessSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> ResettableBrightnessSlider {
        let slider = ResettableBrightnessSlider()
        slider.isContinuous = true
        slider.trackFillColor = NSColor(white: 0.25, alpha: 1)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("灯光亮度")
        slider.toolTip = "拖动调整亮度；双击滑杆恢复 100%"
        configure(slider)
        return slider
    }

    func updateNSView(_ slider: ResettableBrightnessSlider, context: Context) {
        context.coordinator.value = $value
        configure(slider)
    }

    private func configure(_ slider: ResettableBrightnessSlider) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.defaultValue = defaultValue
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.setAccessibilityValueDescription("\(Int(value * 100))%")
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @objc func changed(_ slider: NSSlider) {
            value.wrappedValue = slider.doubleValue
            slider.setAccessibilityValueDescription("\(Int(slider.doubleValue * 100))%")
        }
    }
}

final class ResettableBrightnessSlider: NSSlider {
    var defaultValue = 1.0

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 {
            // Handle the second press before AppKit starts tracking: no later
            // knob update can overwrite the reset or compete with a tap gesture.
            doubleValue = defaultValue
            sendAction(action, to: target)
            return
        }
        super.mouseDown(with: event)
    }
}
