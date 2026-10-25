import Foundation
import CoreGraphics

/// Pure geometry shared by the live gesture and its regression checks.
enum SleeveMotion {
    static func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    static func expansion(origin: CGRect, pointer: CGPoint, start: CGPoint) -> CGFloat {
        // Pull the film through the mouth before enlarging it over the table.
        smooth((start.y - pointer.y - origin.height) / 110)
    }

    static func frame(origin: CGRect, pointer: CGPoint, start: CGPoint, target: CGSize) -> CGRect {
        let t = expansion(origin: origin, pointer: pointer, start: start)
        let size = CGSize(width: origin.width + (target.width - origin.width) * t,
                          height: origin.height + (target.height - origin.height) * t)
        let grabX = min(1, max(0, (start.x - origin.minX) / max(1, origin.width)))
        let grabY = min(1, max(0, (start.y - origin.minY) / max(1, origin.height)))
        return CGRect(x: pointer.x - size.width * grabX, y: pointer.y - size.height * grabY,
                      width: size.width, height: size.height)
    }
}
