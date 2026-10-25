import AppKit
import LightTableCore

/// One immutable membrane for the table and lens, including transparent holes.
@MainActor enum AlbumSurface {
    private static var cache: [String: CGImage] = [:]
    static func image(_ page: AlbumPage, front: Bool) -> CGImage? {
        let key = "\(front)-" + page.pockets.map { "\($0.column),\($0.row),\($0.format.rawValue)" }.joined(separator: ";")
        if let image = cache[key] { return image }
        let scale = 2.0, size = AlbumPage.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        let outer = CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2)
        if !front {
            context.setFillColor(CGColor(gray: 0.78, alpha: 0.13)); context.fill(outer)
            context.setFillColor(CGColor(gray: 0.85, alpha: 0.10)); context.fill(CGRect(x: 2, y: 2, width: 31, height: size.height - 4))
            context.setBlendMode(.clear)
            for row in 0..<9 { context.fillEllipse(in: CGRect(x: 10, y: 50 + row * 72, width: 13, height: 21)) }
            context.setBlendMode(.normal)
        } else {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); context.setLineWidth(1)
            context.stroke(outer.insetBy(dx: 1, dy: 1))
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.17)); context.stroke(outer.insetBy(dx: 3, dy: 3))
            for row in 0..<9 {
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.32))
                context.strokeEllipse(in: CGRect(x: 9, y: 49 + row * 72, width: 15, height: 23))
            }
            context.move(to: CGPoint(x: 34, y: 8)); context.addLine(to: CGPoint(x: 34, y: size.height - 8)); context.strokePath()
            for pocket in page.pockets {
                let rect = AlbumPage.pocketRect(pocket).insetBy(dx: 1, dy: 1)
                context.setFillColor(CGColor(gray: 1, alpha: 0.018)); context.fill(rect)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.17)); context.setLineWidth(1); context.stroke(rect)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.36)); context.setLineWidth(0.8)
                context.stroke(rect.insetBy(dx: 2, dy: 2))
                context.setLineDash(phase: 0, lengths: [1.2, 2.4]); context.setLineWidth(1.5)
                context.move(to: CGPoint(x: rect.minX + 4, y: rect.maxY - 4)); context.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 4)); context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.44)); context.setLineWidth(1.1)
                context.move(to: CGPoint(x: rect.minX + 5, y: rect.minY + 7))
                context.addCurve(to: CGPoint(x: rect.maxX - 5, y: rect.minY + 7),
                    control1: CGPoint(x: rect.midX - 18, y: rect.minY + 10), control2: CGPoint(x: rect.midX + 24, y: rect.minY + 3))
                context.strokePath()
            }
        }
        guard let image = context.makeImage() else { return nil }
        if cache.count >= 32 { cache.removeAll() }
        cache[key] = image; return image
    }
}
