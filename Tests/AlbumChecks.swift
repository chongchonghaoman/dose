import AppKit
import CoreImage
import LightTableCore

@main struct AlbumChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ yes: Bool, _ label: String) {
            guard yes else { fatalError("FAIL \(label)") }
            count += 1; print("PASS \(label)")
        }
        var small = AlbumPage(name: "135")
        small.fillEmptyPage(with: .film135)
        check(small.pockets.count == 20 && small.pockets.last?.column == 12 && small.pockets.last?.row == 9, "135 page has exactly five columns and four rows")
        check(small.add(.film135) == nil && small.add(.film120) == nil, "full page refuses extra pockets")
        var large = AlbumPage(name: "120")
        large.fillEmptyPage(with: .film120)
        check(large.pockets.count == 9 && large.pockets.last?.column == 10 && large.pockets.last?.row == 8, "120 page has exactly three columns and three rows")
        var mixed = AlbumPage(name: "混排")
        let a = mixed.add(.film120, column: 0, row: 0)!
        let b = mixed.add(.film135, column: 5, row: 0)!
        check(mixed.add(.film135, column: 4, row: 0) == nil, "mixed formats cannot overlap")
        check(mixed.add(.film120, column: 12, row: 10) == nil && mixed.add(.film135, column: -1, row: 0) == nil,
              "pockets cannot spill beyond the sheet")
        while mixed.add(.film135) != nil {}
        check(mixed.pockets.contains { $0.format == .film120 } && mixed.pockets.filter { $0.format == .film135 }.count > 1,
              "one page supports both fixed formats")
        for i in mixed.pockets.indices {
            for j in mixed.pockets.indices where i < j {
                precondition(!mixed.pockets[i].rect.intersects(mixed.pockets[j].rect))
            }
        }
        check(true, "mixed auto-placement never overlaps existing pockets")
        let urlA = URL(fileURLWithPath: "/tmp/album-a.png"), urlB = URL(fileURLWithPath: "/tmp/album-b.png")
        small.setPhoto(urlA, in: small.pockets[0].id); small.setPhoto(urlB, in: small.pockets[1].id)
        let firstID = small.pockets[0].id, secondID = small.pockets[1].id
        check(small.move(firstID, column: 3, row: 0), "matching occupied pockets can exchange positions")
        check(small.pockets.first { $0.id == firstID }?.url == urlA && small.pockets.first { $0.id == secondID }?.url == urlB &&
              small.pockets.first { $0.id == secondID }?.column == 0, "swapping keeps each photograph and pocket identity")
        let before = mixed
        check(!mixed.move(a, column: 5, row: 0) && mixed == before, "invalid mixed-size swap is atomic")
        mixed.setPhoto(urlA, in: b); mixed.setPhoto(urlB, in: b)
        check(mixed.pockets.first { $0.id == b }?.url == urlB, "replacement changes only the selected pocket")
        mixed.setPhoto(nil, in: b)
        check(mixed.pockets.first { $0.id == b }?.url == nil && mixed.pockets.contains { $0.id == b }, "clearing a photograph preserves its bag slot")
        for format in FilmFormat.allCases {
            let p = AlbumPocket(format: format, column: 0, row: 0)
            for aspect in [0.25, 0.66, 1, 1.5, 4.0] {
                let image = AlbumPage.imageRect(p, aspect: aspect)
                precondition(abs(image.width / image.height - aspect) < 1e-8 && AlbumPage.pocketRect(p).contains(image))
            }
        }
        check(true, "all photo aspect ratios fit without cropping")
        let smallRect = AlbumPage.imageRect(AlbumPocket(format: .film135, column: 0, row: 0), aspect: 1)
        let largeRect = AlbumPage.imageRect(AlbumPocket(format: .film120, column: 0, row: 0), aspect: 1)
        check(largeRect.width > smallRect.width * 1.5, "120 film has a larger fixed footprint")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.png")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try bytes.write(to: photo)
        let saved = root.appendingPathComponent("layout.json")
        let model = TableModel(restore: false, storageURL: saved)
        model.boardSize = CGSize(width: 1000, height: 700)
        let id = model.newAlbum()
        model.updateAlbum(id) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(photo, in: pocket)
        }
        model.pan = CGPoint(x: -300, y: 140); model.zoom = 0.5
        let drop = CGPoint(x: 220, y: 350), board = CGRect(x: 0, y: 64, width: 1000, height: 700)
        let provider = AlbumDrag.provider(id)
        let accepted = await model.acceptDrop([provider], at: drop, board: board)
        let frame = model.albumFrame(model.albums[0])
        check(accepted && abs(frame.midX - drop.x) < 1e-8 && abs(frame.midY + 64 - drop.y) < 1e-8, "whole-page drop preserves pointer position under camera transforms")
        _ = await model.acceptDrop([provider], at: drop, board: board)
        check(model.albums.count == 1 && model.layout.slides.isEmpty && model.onTableAlbums.count == 1, "repeated page drop does not duplicate or scatter its films")
        let pockets = model.albums[0].pockets
        model.updateAlbum(id) { $0.position = CGPoint(x: -2200, y: 9000) }
        check(model.albums[0].pockets == pockets, "moving a whole page leaves its internal positions unchanged")
        model.place(photo, x: 3, y: -2)
        let slideID = model.layout.slides[0].id
        model.select(id)
        check(model.tableIDs.last == id, "page can be placed above loose films")
        model.select(slideID)
        check(model.tableIDs.last == slideID, "loose film can be placed above a page")
        model.fitToWindow()
        let fitted = model.albumFrame(model.albums[0])
        check(model.albums[0].pockets == pockets && model.layout.slides.count == 1 &&
              CGRect(origin: .zero, size: model.boardSize).contains(fitted), "command zero arranges pages intact and shows the complete sheet")
        model.flushSave()
        let restored = TableModel(storageURL: saved)
        check(restored.albums == model.albums && restored.layout == model.layout && restored.tableIDs == model.tableIDs,
              "pages, individual films, and stacking survive relaunch")
        check(restored.allPhotos.contains { $0.url == photo }, "page-only photo references remain available in the shared album library")
        var old: [String: Any] = try JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as! [String: Any]
        old.removeValue(forKey: "albums"); old.removeValue(forKey: "tableOrder")
        let legacy = root.appendingPathComponent("legacy.json")
        try JSONSerialization.data(withJSONObject: old).write(to: legacy)
        let legacyModel = TableModel(storageURL: legacy)
        check(legacyModel.albums.isEmpty && legacyModel.layout == model.layout, "old layouts without album fields remain readable")
        model.select(id); model.removeSelected()
        check(model.albums.count == 1 && model.onTableAlbums.isEmpty && model.albums[0].pockets == pockets,
              "taking a page off the table preserves the album contents")
        model.placeAlbum(id); model.clear()
        check(model.albums.count == 1 && model.onTableAlbums.isEmpty && model.layout.slides.isEmpty,
              "clearing the table does not delete the album")
        check(try Data(contentsOf: photo) == bytes, "album operations never rewrite source files")

        let back = AlbumSurface.image(mixed, front: false)!, front = AlbumSurface.image(mixed, front: true)!
        check(AlbumSurface.image(mixed, front: true) === front, "membrane images are reused while moving the magnifier")
        let renderer = LoupeRenderer()
        let center = CGPoint(x: 310, y: 345)
        let surfaces = [back, front].map { LoupeScenePhoto(preview: nil, center: center, imageSize: AlbumPage.size, mountScale: 0, surface: $0) }
        let output = renderer.render(photos: surfaces, point: CGPoint(x: 80, y: 70), diameter: 260, magnification: 1.5,
                                    displayScale: 2, transmission: 1, flare: 0, brightness: 1)!
        check(output.width == 520 && output.height == 520, "transparent album surfaces render in the high-resolution lens")
        check(LoupeScenePhoto(preview: nil, center: center, imageSize: CGSize(width: 100, height: 80)).bounds ==
              CGRect(x: 260, y: 305, width: 100, height: 80), "films add no second black frame in the magnifier")
        print("RESULT \(count) passed; 0 failed")
    }
}
