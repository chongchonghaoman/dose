import Foundation

public struct Slide: Identifiable, Codable, Equatable, Sendable {
    public static let defaultWidth = 0.38
    public let id: UUID
    public let url: URL
    public var x: Double
    public var y: Double
    public var width: Double
    public var angle: Double

    public init(id: UUID = UUID(), url: URL, x: Double, y: Double,
                width: Double = Slide.defaultWidth, angle: Double = 0) {
        self.id = id; self.url = url.standardizedFileURL
        self.x = x.isFinite ? x : 0.5
        self.y = y.isFinite ? y : 0.5
        self.width = Self.finite(width, in: 0.12...0.9, fallback: Self.defaultWidth)
        self.angle = angle.isFinite ? angle.truncatingRemainder(dividingBy: 360) : 0
    }

    public func normalized() -> Slide {
        Slide(id: id, url: url, x: x, y: y, width: width, angle: angle)
    }

    private static func finite(_ n: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
    }
}

/// The document owns placement only. It cannot edit or delete photo files.
public struct TableLayout: Codable, Equatable, Sendable {
    public private(set) var slides: [Slide] = []
    public init() {}

    @discardableResult
    public mutating func place(_ url: URL, x: Double, y: Double) -> UUID {
        let canonical = url.standardizedFileURL
        if let old = slides.first(where: { $0.url == canonical }) {
            update(old.id) { $0.x = x; $0.y = y }
            bringToFront(old.id)
            return old.id
        }
        let slide = Slide(url: canonical, x: x, y: y)
        slides.append(slide)
        return slide.id
    }

    public mutating func update(_ id: UUID, _ change: (inout Slide) -> Void) {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return }
        change(&slides[i]); slides[i] = slides[i].normalized()
    }

    public mutating func bringToFront(_ id: UUID) {
        guard let i = slides.firstIndex(where: { $0.id == id }) else { return }
        slides.append(slides.remove(at: i))
    }

    public mutating func remove(_ id: UUID) { slides.removeAll { $0.id == id } }
    public mutating func clear() { slides.removeAll() }

    /// Explicit fit command only: reset individual sizes, then center a grid.
    /// Return a shared display scale, keeping the default document size intact.
    @discardableResult
    public mutating func fitToWindow(boardWidth: Double, boardHeight: Double,
                                     imageAspects: [URL: Double]) -> Double {
        guard boardWidth.isFinite, boardHeight.isFinite, boardWidth > 0, boardHeight > 0 else { return 1 }
        guard !slides.isEmpty else { return 1 }
        let baseWidth = min(boardWidth, boardHeight) * Slide.defaultWidth
        let inset = min(24, min(boardWidth, boardHeight) * 0.05)
        let availableW = boardWidth - 2 * max(inset, boardWidth * 0.03)
        let availableH = boardHeight - 2 * max(inset, boardHeight * 0.03)
        let gap = min(20, min(boardWidth, boardHeight) * 0.035)
        // Bounding boxes follow the source image edges and rotation, without an extra mount.
        let bounds = slides.map { slide -> (w: Double, h: Double, borderW: Double, borderH: Double) in
            let raw = imageAspects[slide.url] ?? 1.5
            let aspect = raw.isFinite && raw > 0 ? raw : 1.5
            let c = abs(cos(slide.angle * .pi / 180)), s = abs(sin(slide.angle * .pi / 180))
            return (baseWidth * (c + s / aspect), baseWidth * (s + c / aspect),
                    0, 0)
        }
        var bestColumns = 1, bestScale = -Double.infinity, bestShape = Double.infinity
        for columns in 1...slides.count {
            let rows = (slides.count + columns - 1) / columns
            let cellW = (availableW - Double(columns - 1) * gap) / Double(columns)
            let cellH = (availableH - Double(rows - 1) * gap) / Double(rows)
            let scale = bounds.reduce(1.0) { min($0, (cellW - $1.borderW) / $1.w, (cellH - $1.borderH) / $1.h) }
            guard scale > 0 else { continue }
            let frameW = bounds.map { $0.w * scale + $0.borderW }.max()!
            let frameH = bounds.map { $0.h * scale + $0.borderH }.max()!
            let gridW = Double(columns) * frameW + Double(columns - 1) * gap
            let gridH = Double(rows) * frameH + Double(rows - 1) * gap
            let shape = abs(log((gridW / gridH) / (availableW / availableH)))
            if scale > bestScale + 1e-10 || (abs(scale - bestScale) < 1e-10 && shape < bestShape) {
                bestColumns = columns; bestScale = scale; bestShape = shape
            }
        }
        guard bestScale > 0 else { return 1 }
        let rows = (slides.count + bestColumns - 1) / bestColumns
        let frameW = bounds.map { $0.w * bestScale + $0.borderW }.max()!
        let frameH = bounds.map { $0.h * bestScale + $0.borderH }.max()!
        let gridH = Double(rows) * frameH + Double(rows - 1) * gap
        for i in slides.indices {
            let row = i / bestColumns, column = i % bestColumns
            let rowCount = min(bestColumns, slides.count - row * bestColumns)
            let rowW = Double(rowCount) * frameW + Double(rowCount - 1) * gap
            slides[i].width = Slide.defaultWidth
            slides[i].x = ((boardWidth - rowW) / 2 + frameW / 2 + Double(column) * (frameW + gap)) / boardWidth
            slides[i].y = ((boardHeight - gridH) / 2 + frameH / 2 + Double(row) * (frameH + gap)) / boardHeight
        }
        return bestScale
    }

    /// Restored files are untrusted input, including coordinates and repeated IDs.
    public func sanitized() -> TableLayout {
        var result = TableLayout()
        var urls = Set<URL>(), ids = Set<UUID>()
        for slide in slides where slide.url.isFileURL {
            let value = slide.normalized()
            guard !urls.contains(value.url), !ids.contains(value.id) else { continue }
            urls.insert(value.url); ids.insert(value.id)
            result.slides.append(value)
        }
        return result
    }
}

public enum TableCoordinates {
    /// Resolve the visible image without changing order; only source pixels
    /// occlude lower photographs, with no additional synthetic film mount.
    public static func topmostImageHit(_ slides: [Slide], x: Double, y: Double,
                                      boardWidth: Double, boardHeight: Double,
                                      imageAspects: [URL: Double], zoom: Double = 1) -> SlideImageHit? {
        for slide in slides.reversed() {
            let p = placement(slide, boardWidth: boardWidth, boardHeight: boardHeight,
                              imageAspect: imageAspects[slide.url] ?? 1.5, zoom: zoom)
            let local = localPoint(x: x, y: y, centerX: p.x, centerY: p.y, angle: p.angle)
            guard abs(local.x) <= p.width / 2, abs(local.y) <= p.height / 2 else { continue }
            return SlideImageHit(slide: slide, placement: p, x: local.x + p.width / 2, y: local.y + p.height / 2)
        }
        return nil
    }

    public static func fit(width: Double, height: Double) -> (width: Double, height: Double) {
        (max(1, width), max(1, height))
    }

    /// Unbounded world placement. Window edges belong to the viewport, not the document.
    public static func placement(_ slide: Slide, boardWidth: Double, boardHeight: Double,
                                 imageAspect: Double, zoom: Double = 1) -> SlidePlacement {
        let bw = max(1, boardWidth), bh = max(1, boardHeight)
        let aspect = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 1.5
        let width = max(1, min(bw, bh) * slide.width * zoom)
        return SlidePlacement(x: slide.x * bw, y: slide.y * bh,
                              width: width, height: width / aspect, angle: slide.angle)
    }

    /// Image-local coordinates, including a rotated slide's placement.
    public static func localPoint(x: Double, y: Double, centerX: Double,
                                  centerY: Double, angle: Double) -> (x: Double, y: Double) {
        let r = -angle * .pi / 180
        let dx = x - centerX, dy = y - centerY
        return (dx * cos(r) - dy * sin(r), dx * sin(r) + dy * cos(r))
    }
}

public struct SlideImageHit: Sendable {
    public let slide: Slide
    public let placement: SlidePlacement
    public let x: Double
    public let y: Double
}

public struct SlidePlacement: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let angle: Double
}

/// A camera over an unbounded table; document coordinates never depend on panning.
public struct TableViewport: Codable, Equatable, Sendable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.offsetX = offsetX.isFinite ? offsetX : 0
        self.offsetY = offsetY.isFinite ? offsetY : 0
    }

    public func screen(x: Double, y: Double) -> (x: Double, y: Double) {
        (x * scale + offsetX, y * scale + offsetY)
    }
    public func world(x: Double, y: Double) -> (x: Double, y: Double) {
        ((x - offsetX) / scale, (y - offsetY) / scale)
    }
    public func screen(_ p: SlidePlacement) -> SlidePlacement {
        let center = screen(x: p.x, y: p.y)
        return SlidePlacement(x: center.x, y: center.y, width: p.width * scale,
                              height: p.height * scale, angle: p.angle)
    }
    public mutating func zoom(to value: Double, aroundX x: Double, aroundY y: Double) {
        let anchor = world(x: x, y: y)
        scale = min(8, max(0.05, value))
        offsetX = x - anchor.x * scale
        offsetY = y - anchor.y * scale
    }

    /// Points per second, with a gentle ramp at each viewport edge.
    public static func edgeVelocity(x: Double, y: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        func axis(_ position: Double, _ length: Double) -> Double {
            let band = min(48, length / 4)
            guard band > 0 else { return 0 }
            if position < band { return 420 * min(1, max(0, (band - position) / band)) }
            if position > length - band { return -420 * min(1, max(0, (position - length + band) / band)) }
            return 0
        }
        return (axis(x, width), axis(y, height))
    }
}
