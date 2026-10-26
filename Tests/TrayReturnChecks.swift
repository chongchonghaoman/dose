import AppKit
import LightTableCore

@main struct TrayReturnChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("TrayReturnChecks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); count += 1; print("PASS \(label)")
        }
        func photo(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".png").standardizedFileURL
            try data.write(to: url); return url
        }
        let a = try photo("a"), b = try photo("b"), c = try photo("c"), d = try photo("d")
        let storage = root.appendingPathComponent("layout.json")
        let model = TableModel(restore: false, storageURL: storage)
        model.boardSize = CGSize(width: 1000, height: 700)
        await model.importURLs([a, b, c])
        let originalOrder = model.photos.map(\.url)
        let firstTray = model.activeTrayID
        check(model.trayPhotos.map(\.url) == originalOrder, "imported photos initially remain in the tray")
        model.place(b, x: 0.3, y: 0.4)
        let bID = model.selectedID!
        check(model.trayPhotos.map(\.url) == originalOrder.filter { $0 != b }, "placed photo disappears and remaining order stays stable")
        check(model.photos.map(\.url) == originalOrder, "placing preserves source membership and order")
        model.place(b, x: 0.4, y: 0.5)
        check(model.layout.slides.count == 1 && model.selectedID == bID, "repeated placement creates no duplicate")
        model.update(bID) { $0.angle = 20; $0.width = 0.4 }
        check(model.trayPhotos.map(\.url) == originalOrder.filter { $0 != b }, "moving and rotating do not return a placed photo")
        let thumb = await PhotoThumbnails.shared.thumbnail(b)!
        model.cacheThumbnail(thumb, for: b)
        model.removeSelected()
        check(model.trayPhotos.map(\.url) == originalOrder && model.layout.slides.isEmpty, "Delete returns the film to its original ordered position")
        check(model.thumbnails[b] === thumb, "returned film reuses its cached thumbnail")
        model.removeSelected()
        check(model.trayPhotos.map(\.url) == originalOrder, "repeated Delete with no selection cannot duplicate photos")

        model.place(a, x: 0.2, y: 0.3)
        let aID = model.selectedID!
        let secondTray = model.newTray()
        await model.importURLs([d])
        model.place(d, x: 0.7, y: 0.6)
        let dID = model.selectedID!
        model.setSelection([aID, dID])
        model.removeSelected()
        check(model.activeTrayID == secondTray && model.trayPhotos.map(\.url) == [d], "mixed return keeps the active tray and never moves another tray's photo into it")
        model.selectTray(firstTray)
        check(model.trayPhotos.map(\.url) == originalOrder, "mixed return restores each photo to its original tray")
        model.place(b, x: 0.4, y: 0.4)
        model.selectTray(secondTray)
        model.flushSave()
        let restored = TableModel(storageURL: storage)
        check(restored.activeTrayID == secondTray && restored.trayPhotos.map(\.url) == [d], "restart restores current tray selection")
        restored.selectTray(firstTray)
        check(restored.trayPhotos.map(\.url) == originalOrder.filter { $0 != b }, "restart hides already-placed films in their original tray")
        restored.select(restored.layout.slides.first { $0.url == b }!.id)
        restored.selectTray(secondTray)
        restored.removeSelected()
        check(restored.trayPhotos.map(\.url) == [d], "Delete after restart and tray switch does not redirect the returned film")
        restored.selectTray(firstTray)
        check(restored.trayPhotos.map(\.url) == originalOrder, "returned film's original order survives restart")
        restored.flushSave()
        let afterReturn = TableModel(storageURL: storage)
        check(afterReturn.trayPhotos.map(\.url) == originalOrder && afterReturn.layout.slides.isEmpty,
              "returned state survives another restart")

        model.selectTray(firstTray)
        model.boardSize = CGSize(width: 1000, height: 700)
        model.placeAllPhotos()
        check(model.trayPhotos.isEmpty && Set(model.layout.slides.map(\.url)) == Set(originalOrder), "place all empties visible tray without losing library photos")
        model.enterSlideshow()
        check(model.slideshowMode && Set(model.slideshowOrder) == Set(originalOrder), "empty visible tray still permits the current tray's complete slideshow")
        model.exitSlideshow()
        model.clear()
        check(model.trayPhotos.map(\.url) == originalOrder, "clear table returns every photo to its original tray")
        let cancelledLayout = model.layout
        let cancelledPhotos = model.trayPhotos
        let outside = CGRect(x: 0, y: 0, width: 100, height: 100)
        _ = await model.acceptDrop([PhotoDrag.provider(for: Photo(url: a))], at: CGPoint(x: -20, y: -20), board: outside)
        check(model.layout == cancelledLayout && model.trayPhotos == cancelledPhotos, "invalid drop keeps photo in tray without changing table")
        _ = await model.acceptDrop([PhotoDrag.provider(for: Photo(url: a))], at: CGPoint(x: 40, y: 40), board: outside)
        check(!model.trayPhotos.contains { $0.url == a }, "native internal drop also removes the visible tray entry")
        model.removeSelected()
        check(model.trayPhotos.map(\.url) == originalOrder, "native drop and return maintain original order")
        await model.importURLs([a, b, c])
        check(model.trayPhotos.map(\.url) == originalOrder, "reimporting returned photos does not duplicate them")
        model.place(b, x: 0.5, y: 0.5)
        await model.importURLs([b])
        check(!model.trayPhotos.contains { $0.url == b }, "reimporting a placed photo keeps it off the tray")
        let album = model.newAlbum()
        model.updateAlbum(album) { page in let pocket = page.add(.film135)!; page.setPhoto(c, in: pocket) }
        model.placeAlbum(album)
        model.removeSelected()
        check(model.albums.first { $0.id == album }?.pockets.contains { $0.url == c } == true,
              "returning an album preserves its photos and existing page behavior")

        let cached = TableModel(restore: false)
        var cacheURLs: [URL] = []
        for i in 0..<14 {
            let url = try photo("cache-\(i)"); cacheURLs.append(url)
            cached.place(url, x: 0.5, y: 0.5)
            _ = await cached.preparePreview(url)
            _ = await cached.prepareTablePreview(url, maxPixel: 256)
        }
        check(cached.preparedPreviews.count == 14 && cached.preparedTablePreviews.count == 14, "on-table photos retain prepared previews")
        cached.setSelection(Set(cached.tableIDs))
        cached.removeSelected()
        check(cached.preparedPreviews.count <= 12 && cached.preparedTablePreviews.count <= 12,
              "returning films immediately trims off-table model previews to the existing cache limit")
        check(cached.trayPhotos.count == 14 && cached.photos.count == 14, "cache trimming retains every returned photo")
        for url in [a, b, c, d] + cacheURLs {
            check(try Data(contentsOf: url) == data, "original unchanged: \(url.lastPathComponent)")
        }
        print("Tray return: \(count) checks passed")
    }
}
