import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Runs against production sources without XCTest, so Command Line Tools suffice.
@main
struct SmokeChecks {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }
    static var passes = 0
    static var failures = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckFailure(description: message) }
    }

    static func check(_ name: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            passes += 1
            print("PASS  \(name)")
        } catch {
            failures += 1
            print("FAIL  \(name): \(error)")
        }
    }

    static func main() async {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LightTableSmoke-" + UUID().uuidString, isDirectory: true)
        do { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { print("FAIL  temporary fixture: \(error)"); exit(1) }
        defer { try? manager.removeItem(at: root) }
        let first = root.appendingPathComponent("image2.png")
        let second = root.appendingPathComponent("image10.png")

        await check("Drop coordinates remain exact; adding a photo never arranges earlier slides") {
            var table = TableLayout()
            let id = table.place(first, x: 0.27, y: 0.61)
            table.update(id) { $0.angle = 23; $0.width = 0.42 }
            let before = table.slides[0]
            table.place(second, x: 0.75, y: 0.2)
            try require(table.slides[0] == before, "existing placement changed")
            try require(table.slides[1].x == 0.75 && table.slides[1].y == 0.2, "drop coordinate changed")
        }

        await check("Repeated drop keeps one identity, moves it and raises it") {
            var table = TableLayout()
            let id = table.place(first, x: 0.2, y: 0.2)
            table.update(id) { $0.angle = 17; $0.width = 0.51 }
            table.place(second, x: 0.7, y: 0.7)
            let alias = root.appendingPathComponent("nested/../image2.png")
            try require(table.place(alias, x: 0.4, y: 0.6) == id, "duplicate gained another identity")
            try require(table.slides.count == 2 && table.slides.last?.id == id, "duplicate or wrong stacking order")
            let moved = table.slides[1]
            try require(moved.x == 0.4 && moved.y == 0.6 && moved.angle == 17 && moved.width == 0.51, "placement or transform lost")
        }

        await check("Loupe always samples the visible photo without raising covered slides") {
            var table = TableLayout()
            let lower = table.place(first, x: 0.5, y: 0.5)
            let upper = table.place(second, x: 0.5, y: 0.5)
            table.update(lower) { $0.width = 0.8 }
            table.update(upper) { $0.width = 0.4 }
            let before = table.slides
            let aspects = [first: 1.0, second: 1.0]
            func hit(_ x: Double, _ y: Double) -> SlideImageHit? {
                TableCoordinates.topmostImageHit(table.slides, x: x, y: y,
                    boardWidth: 1000, boardHeight: 800, imageAspects: aspects)
            }
            try require(hit(500, 400)?.slide.id == upper, "covered photo stole lens focus")
            try require(hit(250, 400)?.slide.id == lower, "visible lower photo was not sampled")
            try require(hit(662, 400)?.slide.id == lower, "synthetic frame obscures the lower image")
            try require(hit(10, 10) == nil, "blank table had lens focus")
            for _ in 0..<100 { _ = hit(500, 400); _ = hit(250, 400) }
            try require(table.slides == before, "hover changed stacking or geometry")
        }

        await check("Loupe hit testing respects rotated photo and mount geometry") {
            var table = TableLayout()
            let id = table.place(first, x: 0.5, y: 0.5)
            table.update(id) { $0.width = 0.4; $0.angle = 90 }
            let hit = TableCoordinates.topmostImageHit(table.slides, x: 450, y: 500,
                boardWidth: 1000, boardHeight: 800, imageAspects: [first: 2.0])
            try require(hit?.slide.id == id, "rotated visible photo was missed")
            try require(abs((hit?.x ?? 0) - 260) < 0.001 && abs((hit?.y ?? 0) - 130) < 0.001, "pointer mapped to wrong image pixel")
            let outside = TableCoordinates.topmostImageHit(table.slides, x: 600, y: 400,
                boardWidth: 1000, boardHeight: 800, imageAspects: [first: 2.0])
            try require(outside == nil, "unrotated bounds were used")
        }

        await check("Transform normalization preserves unbounded positions and rejects nonfinite numbers") {
            var table = TableLayout()
            let id = table.place(first, x: .nan, y: .infinity)
            try require(table.slides[0].x == 0.5 && table.slides[0].y == 0.5, "invalid placement fallback failed")
            table.update(id) { $0.width = -99; $0.angle = .infinity; $0.x = -20; $0.y = 999 }
            let small = table.slides[0]
            try require(small.x == -20 && small.y == 999 && small.width == 0.12 && small.angle == 0, "lower bounds failed")
            table.update(id) { $0.width = 99; $0.angle = 757 }
            try require(table.slides[0].width == 0.9 && table.slides[0].angle == 37, "upper width/rotation bounds failed")
            table.update(id) { $0.width = .nan; $0.angle = -397 }
            try require(table.slides[0].width == 0.38 && table.slides[0].angle == -37, "fallback/negative rotation failed")
        }

        await check("JSON roundtrip preserves geometry and stacking order") {
            var table = TableLayout()
            let id = table.place(first, x: 0.23, y: 0.73)
            table.update(id) { $0.width = 0.6; $0.angle = 37 }
            table.place(second, x: 0.65, y: 0.2)
            table.bringToFront(id)
            let restored = try JSONDecoder().decode(TableLayout.self, from: JSONEncoder().encode(table)).sanitized()
            try require(restored == table, "roundtrip changed document")
        }

        await check("Restoration sanitizes repeated URLs/IDs, remote URLs and out-of-range geometry") {
            let id = UUID()
            let rows: [[String: Any]] = [
                ["id": id.uuidString, "url": first.absoluteString, "x": -2, "y": 4, "width": 5, "angle": 737],
                ["id": UUID().uuidString, "url": first.absoluteString, "x": 0.5, "y": 0.5, "width": 0.4, "angle": 0],
                ["id": id.uuidString, "url": second.absoluteString, "x": 0.5, "y": 0.5, "width": 0.4, "angle": 0],
                ["id": UUID().uuidString, "url": "https://example.invalid/photo.png", "x": 0.5, "y": 0.5, "width": 0.4, "angle": 0]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["slides": rows])
            let restored = try JSONDecoder().decode(TableLayout.self, from: data).sanitized()
            try require(restored.slides.count == 1, "untrusted duplicate/remote slide survived")
            let slide = restored.slides[0]
            try require(slide.x == -2 && slide.y == 4 && slide.width == 0.9 && slide.angle == 17, "restored geometry not normalized")
        }

        await check("Remove and clear leave original file bytes intact") {
            let file = root.appendingPathComponent("source-safety.bin")
            let bytes = Data([0, 1, 2, 3, 255])
            try bytes.write(to: file)
            var table = TableLayout()
            table.remove(table.place(file, x: 0.5, y: 0.5))
            try require(table.slides.isEmpty, "remove left a slide")
            table.place(file, x: 0.5, y: 0.5)
            table.clear()
            try require(table.slides.isEmpty, "clear left a slide")
            let after = try Data(contentsOf: file)
            try require(after == bytes, "source bytes changed")
        }

        await check("An invalid duplicate ID does not suppress a later valid restored photo") {
            let firstID = UUID()
            let secondID = UUID()
            let rows: [[String: Any]] = [
                ["id": firstID.uuidString, "url": first.absoluteString, "x": 0.2, "y": 0.3, "width": 0.4, "angle": 0],
                ["id": firstID.uuidString, "url": second.absoluteString, "x": 0.5, "y": 0.5, "width": 0.4, "angle": 0],
                ["id": secondID.uuidString, "url": second.absoluteString, "x": 0.7, "y": 0.6, "width": 0.4, "angle": 0]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["slides": rows])
            let restored = try JSONDecoder().decode(TableLayout.self, from: data).sanitized()
            try require(restored.slides.count == 2 && restored.slides.last?.id == secondID, "a rejected duplicate ID consumed the later valid photo URL")
        }

        await check("Table fills workspace; loupe inverts rotated coordinates") {
            let small = TableCoordinates.fit(width: 800, height: 700)
            let large = TableCoordinates.fit(width: 1600, height: 1400)
            try require(small.width == 800 && small.height == 700, "table does not fill workspace")
            try require(large.width > small.width, "board does not grow with available space")
            let p = TableCoordinates.localPoint(x: 100, y: 130, centerX: 100, centerY: 100, angle: 90)
            try require(abs(p.x - 30) < 1e-9 && abs(p.y) < 1e-9, "loupe inverse rotation failed")
        }

        await check("World placement preserves photos beyond every workspace edge") {
            for board in [(840.0, 330.0), (1180.0, 550.0), (900.0, 1000.0)] {
                for angle in [0.0, 15, 45, 90, 135, 270, -30] {
                    for aspect in [0.2, 0.66, 1.5, 4.0] {
                        for x in [-3.0, 0.5, 4.0] {
                            for y in [-3.0, 0.5, 4.0] {
                                for zoom in [0.65, 1.0, 1.5] {
                                    let slide = Slide(url: first, x: x, y: y, width: 0.9, angle: angle)
                                    let fit = TableCoordinates.placement(slide, boardWidth: board.0, boardHeight: board.1, imageAspect: aspect, zoom: zoom)
                                    try require(abs(fit.x - x * board.0) < 1e-8 && abs(fit.y - y * board.1) < 1e-8,
                                                "offscreen coordinates were clamped")
                                    try require(abs(fit.width - min(board.0, board.1) * 0.9 * zoom) < 1e-8,
                                                "window edge silently reduced photo size")
                                }
                            }
                        }
                    }
                }
            }
        }

        await check("Camera inverse, zoom anchor, and four edge velocities remain consistent") {
            for scale in [0.05, 0.5, 1.0, 2.0, 8.0] {
                var camera = TableViewport(scale: scale, offsetX: -2800, offsetY: 1600)
                let screen = camera.screen(x: -1700, y: 2400)
                let world = camera.world(x: screen.x, y: screen.y)
                try require(abs(world.x + 1700) < 1e-8 && abs(world.y - 2400) < 1e-8, "coordinate inverse drifted")
                let before = camera.world(x: 250, y: 400)
                camera.zoom(to: 1.7, aroundX: 250, aroundY: 400)
                let after = camera.world(x: 250, y: 400)
                try require(abs(before.x - after.x) < 1e-8 && abs(before.y - after.y) < 1e-8, "zoom moved its anchor")
            }
            let leftTop = TableViewport.edgeVelocity(x: 1, y: 1, width: 840, height: 640)
            let rightBottom = TableViewport.edgeVelocity(x: 839, y: 639, width: 840, height: 640)
            let center = TableViewport.edgeVelocity(x: 420, y: 320, width: 840, height: 640)
            try require(leftTop.x > 0 && leftTop.y > 0 && rightBottom.x < 0 && rightBottom.y < 0,
                        "dragging cannot extend all four edges")
            try require(center.x == 0 && center.y == 0, "middle of table unexpectedly scrolls")
        }

        await check("Fit resets all sizes, preserves identities and rotations, and is repeatable") {
            var table = TableLayout()
            let a = table.place(first, x: 0.03, y: 0.97)
            let b = table.place(second, x: 0.04, y: 0.96)
            table.update(a) { $0.width = 0.9; $0.angle = 30 }
            table.update(b) { $0.width = 0.12; $0.angle = -15 }
            let before = table.slides
            let scale = table.fitToWindow(boardWidth: 1180, boardHeight: 550, imageAspects: [:])
            try require(table.slides.allSatisfy { $0.width == Slide.defaultWidth }, "individual widths were not reset")
            for (old, new) in zip(before, table.slides) {
                try require(old.id == new.id && old.url == new.url && old.angle == new.angle, "identity, order or rotation changed")
            }
            let fitted = table
            let again = table.fitToWindow(boardWidth: 1180, boardHeight: 550, imageAspects: [:])
            try require(table == fitted && scale == again, "repeated fit changed layout")
        }

        await check("Fit centers one default-sized slide and handles an empty table") {
            var table = TableLayout()
            try require(table.fitToWindow(boardWidth: 840, boardHeight: 330, imageAspects: [:]) == 1 && table.slides.isEmpty, "empty fit failed")
            let id = table.place(first, x: 0.1, y: 0.9)
            table.update(id) { $0.width = 0.8 }
            let scale = table.fitToWindow(boardWidth: 1180, boardHeight: 550, imageAspects: [first: 1.5])
            try require(scale == 1 && table.slides[0].x == 0.5 && table.slides[0].y == 0.5 && table.slides[0].width == Slide.defaultWidth, "one slide was not centered at default size")
        }

        await check("Fitted mixed photos never overlap or escape across counts and window shapes") {
            for board in [(840.0, 330.0), (1180.0, 550.0), (900.0, 1000.0), (1800.0, 420.0)] {
                for count in [1, 2, 3, 5, 8, 12, 30, 60, 100] {
                    var table = TableLayout()
                    var aspects: [URL: Double] = [:]
                    for i in 0..<count {
                        let url = root.appendingPathComponent("fit-\(i).png")
                        let id = table.place(url, x: 0.5, y: 0.5)
                        aspects[url] = [0.4, 0.66, 1.0, 1.5, 3.0][i % 5]
                        table.update(id) { $0.width = i.isMultiple(of: 2) ? 0.9 : 0.12; $0.angle = [0.0, 30, 90, -15][i % 4] }
                    }
                    let scale = table.fitToWindow(boardWidth: board.0, boardHeight: board.1, imageAspects: aspects)
                    try require(scale > 0 && scale <= 1 && table.slides.allSatisfy { $0.width == Slide.defaultWidth }, "invalid fitted scale or default width")
                    var rectangles: [CGRect] = []
                    for slide in table.slides {
                        let p = TableCoordinates.placement(slide, boardWidth: board.0, boardHeight: board.1, imageAspect: aspects[slide.url]!, zoom: scale)
                        let c = abs(cos(p.angle * .pi / 180)), s = abs(sin(p.angle * .pi / 180))
                        let w = p.width * c + p.height * s
                        let h = p.width * s + p.height * c
                        let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                        try require(rect.minX >= -1e-8 && rect.maxX <= board.0 + 1e-8 && rect.minY >= -1e-8 && rect.maxY <= board.1 + 1e-8, "escaped edge at count \(count)")
                        try require(rectangles.allSatisfy { !$0.intersects(rect) }, "overlap at count \(count), board \(board)")
                        rectangles.append(rect)
                    }
                    let saved = try JSONDecoder().decode(TableLayout.self, from: JSONEncoder().encode(table)).sanitized()
                    try require(saved == table, "saved arrangement was clamped or changed")
                }
            }
        }

        await check("Fit uses the current window and ignores invalid geometry safely") {
            var table = TableLayout()
            for i in 0..<8 { table.place(root.appendingPathComponent("resize-\(i).png"), x: 0.5, y: 0.5) }
            let before = table
            _ = table.fitToWindow(boardWidth: .nan, boardHeight: 550, imageAspects: [:])
            try require(table == before, "invalid board changed layout")
            _ = table.fitToWindow(boardWidth: 1600, boardHeight: 400, imageAspects: [:])
            let wide = table
            _ = table.fitToWindow(boardWidth: 840, boardHeight: 1000, imageAspects: [:])
            try require(table != wide, "fit ignored the new window shape")
        }

        await check("Folder scan recurses, filters hidden/packages/nonimages and deduplicates imports") {
            let nested = root.appendingPathComponent("nested/deep/image3.png")
            let hidden = root.appendingPathComponent(".hidden.png")
            let hiddenChild = root.appendingPathComponent(".secret/image4.png")
            let packageChild = root.appendingPathComponent("Example.app/Contents/Resources/image5.png")
            for file in [first, second, nested, hidden, hiddenChild, packageChild] { try writePNG(to: file, width: 32, height: 24) }
            try Data("not an image".utf8).write(to: root.appendingPathComponent("notes.txt"))
            try manager.createDirectory(at: root.appendingPathComponent("folder.png"), withIntermediateDirectories: true)
            let urls = PhotoLibrary.scan([root, first, root.appendingPathComponent("missing.png"), URL(string: "https://example.invalid/photo.png")!])
            let expected = [first, nested, second].map(\.standardizedFileURL)
            try require(urls == expected, "expected image2,image3,image10 only; got \(urls.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") })")
            try require(PhotoLibrary.scan([root, first, nested]) == expected, "explicit and recursive imports produced duplicates")
            try require(!PhotoLibrary.supported(root.appendingPathComponent("notes.txt")), "text file accepted")
            try require(!PhotoLibrary.supported(URL(string: "https://example.invalid/photo.png")!), "remote URL accepted")
        }

        await check("Preview and thumbnail stay bounded; light reveals detail without changing originals") {
            let source = root.appendingPathComponent("preview-fixture.png")
            try writePNG(to: source, width: 2400, height: 1600)
            let before = try Data(contentsOf: source)
            let store = PhotoStore()
            guard let preview = await store.preview(source), let thumb = await store.thumbnail(source) else {
                throw CheckFailure(description: "image preview failed to decode")
            }
            try require(max(preview.lit.width, preview.lit.height) <= 2200, "full preview exceeded bound")
            try require(max(thumb.width, thumb.height) <= 220, "thumbnail exceeded bound")
            try require(preview.lit.width == preview.dark.width && preview.lit.height == preview.dark.height, "lighting changes image geometry")
            let lit = try meanLuminance(preview.lit)
            let dark = try meanLuminance(preview.dark)
            print(String(format: "      preview luminance: lit=%.4f dark=%.4f ratio=%.2fx", lit, dark, lit / max(dark, 0.0001)))
            try require(lit > 0.3 && dark > 0 && dark < lit * 0.5, "on/off brightness separation is insufficient")
            let cached = await store.preview(source)
            try require(cached?.lit.width == preview.lit.width, "cached preview failed")
            let after = try Data(contentsOf: source)
            try require(before == after, "preview processing changed original bytes")
            let broken = root.appendingPathComponent("broken.png")
            try Data([0, 1, 2]).write(to: broken)
            let invalid = await store.preview(broken)
            try require(invalid == nil, "corrupt image decoded unexpectedly")
        }

        print("RESULT \(passes) passed; \(failures) failed")
        try? manager.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }

    static func writePNG(to url: URL, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure(description: "could not create fixture pixels")
        }
        let colors: [[CGFloat]] = [[0.9, 0.65, 0.3, 1], [0.2, 0.8, 0.4, 1], [0.3, 0.45, 0.95, 1], [0.95, 0.95, 0.95, 1]]
        for (index, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: width * index / 4, y: 0, width: width / 4, height: height))
        }
        guard let image = context.makeImage(),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckFailure(description: "could not create fixture PNG")
        }
        CGImageDestinationAddImage(output, image, nil)
        try require(CGImageDestinationFinalize(output), "could not save fixture PNG")
    }

    static func meanLuminance(_ image: CGImage) throws -> Double {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CheckFailure(description: "could not sample preview pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            let bytes = buffer.bindMemory(to: UInt8.self)
            var total = 0.0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                total += (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index + 2])) / 255
            }
            return total / Double(size * size)
        }
    }
}
