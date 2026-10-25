import Foundation
import CoreGraphics

@main
struct SleeveChecks {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ label: String) {
            precondition(result, label); checks += 1; print("PASS \(label)")
        }
        let origin = CGRect(x: 30, y: 710, width: 90, height: 56)
        let start = CGPoint(x: 48, y: 752)
        let target = CGSize(width: 280, height: 350)
        let rest = SleeveMotion.frame(origin: origin, pointer: start, start: start, target: target)
        check(rest == origin, "pickup starts at the exact sleeve frame")
        let near = CGPoint(x: start.x + 10, y: start.y - 45)
        let extracted = SleeveMotion.frame(origin: origin, pointer: near, start: start, target: target)
        check(extracted.size == origin.size && extracted.minX == origin.minX + 10, "film slides out at sleeve size before enlarging")
        var previous: CGFloat = 0
        var monotonic = true, anchored = true, bounded = true
        for distance in 0...240 {
            let point = CGPoint(x: start.x + 23, y: start.y - CGFloat(distance))
            let t = SleeveMotion.expansion(origin: origin, pointer: point, start: start)
            let frame = SleeveMotion.frame(origin: origin, pointer: point, start: start, target: target)
            monotonic = monotonic && t >= previous
            bounded = bounded && t >= 0 && t <= 1 && frame.width >= origin.width && frame.width <= target.width
            anchored = anchored && abs(frame.minX + frame.width * 0.2 - point.x) < 0.00001
                && abs(frame.minY + frame.height * 0.75 - point.y) < 0.00001
            previous = t
        }
        check(monotonic, "extraction scale changes continuously without reversing")
        check(bounded, "extraction never overshoots the final size")
        check(anchored, "the grabbed point remains under the pointer throughout enlargement")
        let outside = CGPoint(x: start.x, y: start.y - 210)
        check(SleeveMotion.frame(origin: origin, pointer: outside, start: start, target: target).size == target,
              "fully extracted film matches the table dimensions")
        let below = CGPoint(x: start.x, y: start.y + 50)
        check(SleeveMotion.expansion(origin: origin, pointer: below, start: start) == 0,
              "dragging below the bag does not enlarge the film")
        let resumed = SleeveMotion.frame(origin: origin, pointer: start, start: start, target: target)
        check(resumed == origin && SleeveMotion.smooth(-1) == 0 && SleeveMotion.smooth(2) == 1,
              "return geometry exactly restores the pocket without overshoot")
        print("\(checks) sleeve checks passed.")
    }
}
