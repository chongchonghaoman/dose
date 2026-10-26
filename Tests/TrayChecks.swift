import AppKit
import UniformTypeIdentifiers
import LightTableCore

private final class DeferredFile: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    init() {
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { [weak self] completion in
            self?.lock.lock(); self?.completion = completion; self?.lock.unlock()
            return nil
        }
    }
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func finish(_ url: URL) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(url.dataRepresentation, nil)
    }
}

@main struct TrayChecks {
    struct Legacy: Codable { var urls: [URL]; var layout: TableLayout; var label: String }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LightTableTrayChecks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); count += 1; print("PASS \(message)") }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        func photo(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path).standardizedFileURL
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: url); return url
        }
        let a = try photo("first/a.png"), b = try photo("second/nested/b.png"), c = try photo("third/c.png")
        let storage = root.appendingPathComponent("layout.json")
        let model = TableModel(restore: false, storageURL: storage)
        model.boardSize = CGSize(width: 1000, height: 700)
        let first = model.activeTrayID
        await model.importURLs([a.deletingLastPathComponent()])
        check(model.photos.map(\.url) == [a] && model.sourceLabel == "first", "first folder labels its tray")
        model.place(a, x: 0.25, y: 0.7)
        model.isLit = true; model.pan = CGPoint(x: 18, y: 23); model.zoom = 1.7
        let layout = model.layout, selection = model.selectedIDs, clock = model.lightStartedAt
        await model.importURLs([b.deletingLastPathComponent().deletingLastPathComponent()])
        check(model.photos.map(\.url) == [a, b], "another folder appends recursively without replacing existing photos")
        await model.importURLs([a, b])
        check(model.photos.map(\.url) == [a, b] && model.sourceLabel == "first", "repeat import deduplicates and preserves the tray label")
        await model.importURLs([root.appendingPathComponent("missing")])
        check(model.photos.map(\.url) == [a, b] && model.message != nil && !model.isImporting, "empty or missing imports preserve the tray and finish loading")
        let second = model.newTray()
        check(model.trays.count == 2 && second != first && model.activeTrayID == second && model.photos.isEmpty, "plus creates and selects an empty independent tray")
        check(model.layout == layout && model.selectedIDs == selection && model.isLit && model.lightStartedAt == clock
            && model.pan == CGPoint(x: 18, y: 23) && model.zoom == 1.7, "new tray preserves the shared table and viewing state")
        await model.importURLs([c])
        check(model.photos.map(\.url) == [c] && model.trays[0].urls == [a, b], "import goes only to the selected tray")
        model.selectTray(first)
        check(model.photos.map(\.url) == [a, b], "switching back restores the original tray")
        model.selectTray(UUID())
        check(model.activeTrayID == first, "unknown tray identity cannot change the selection")
        await model.importURLs([a], into: second)
        check(model.photos.map(\.url) == [a, b] && model.trays[1].urls == [c, a], "an import keeps its original destination after selection changes")
        check(Set(model.allPhotos.map(\.url)) == Set([a, b, c]) && model.allPhotos.count == 3, "shared album library deduplicates photos across trays")
        model.selectTray(second)
        model.enterSlideshow()
        check(Set(model.slideshowOrder) == Set([a, c]) && model.slideshowOrder.count == 2, "slideshow uses only the selected tray")
        model.exitSlideshow()
        model.flushSave()
        let restored = TableModel(storageURL: storage)
        check(restored.trays == model.trays && restored.activeTrayID == second && restored.photos.map(\.url) == [c, a], "all trays, order, names and active selection survive restart")
        check(restored.layout == layout && restored.pan == model.pan && restored.zoom == model.zoom, "tray persistence preserves table geometry and camera")
        let saved = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: storage))
        check(Set(saved.urls) == Set([a, b, c]), "legacy-compatible URL list retains every tray photo")
        let empty = model.newTray(); model.flushSave()
        let emptyRestored = TableModel(storageURL: storage)
        check(emptyRestored.activeTrayID == empty && emptyRestored.photos.isEmpty && emptyRestored.trays.count == 3, "empty selected trays stay empty after restart")
        emptyRestored.enterSlideshow()
        check(!emptyRestored.slideshowMode, "an empty selected tray cannot play photos from other trays")
        let oldStorage = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(Legacy(urls: [a, a], layout: layout, label: "旧图库")).write(to: oldStorage)
        let migrated = TableModel(storageURL: oldStorage)
        check(migrated.trays.count == 1 && migrated.sourceLabel == "旧图库" && migrated.photos.map(\.url) == [a], "legacy libraries migrate to one deduplicated tray")
        check(migrated.layout == layout, "legacy migration preserves the existing arrangement")
        migrated.flushSave()
        check(TableModel(storageURL: oldStorage).trays == migrated.trays, "legacy migration is stable across subsequent launches")
        let delayed = DeferredFile()
        model.selectTray(first)
        let drop = Task { await model.acceptDrop([delayed.provider], at: nil, board: nil) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !delayed.waiting {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "drop decoding did not start")
            try await Task.sleep(for: .milliseconds(1))
        }
        model.selectTray(second)
        delayed.finish(c)
        let accepted = await drop.value
        check(accepted && model.trays[0].urls == [a, b, c] && model.trays[1].urls == [c, a], "switching during asynchronous drop decoding cannot redirect the import")
        model.selectTray(empty)
        let internalDrop = await model.acceptDrop([PhotoDrag.provider(for: Photo(url: b))],
            at: CGPoint(x: 400, y: 300), board: CGRect(x: 0, y: 0, width: 1000, height: 700))
        check(internalDrop && model.layout.slides.contains { $0.url == b } && model.photos.isEmpty, "a shared-library internal drag places without adding to another tray")
        model.place(a, x: 0.1, y: 0.2)
        check(model.photos.isEmpty, "placing an already known photo does not pollute the current tray")
        model.selectTray(second); model.placeAllPhotos()
        check(Set(model.layout.slides.map(\.url)) == Set([a, c]) && model.trays[0].urls == [a, b, c], "one-click layout uses the active tray while keeping every tray intact")
        let deletion = TableModel(restore: false, storageURL: root.appendingPathComponent("deletion.json"))
        deletion.boardSize = CGSize(width: 1000, height: 700)
        await deletion.importURLs([a, b])
        let deletionFirst = deletion.activeTrayID
        deletion.place(a, x: 0.2, y: 0.3)
        let placedID = deletion.selectedID!
        deletion.selectTrayForDeletion(deletionFirst)
        check(deletion.selectedTrayForDeletion == deletionFirst && deletion.selectedIDs.isEmpty,
              "clicking a tray targets Delete at the tray and clears table selection")
        deletion.selectTrayForDeletion(deletionFirst)
        check(deletion.selectedTrayForDeletion == deletionFirst, "clicking the already-active tray still targets it for deletion")
        deletion.select(placedID)
        check(deletion.selectedTrayForDeletion == nil && deletion.selectedID == placedID,
              "clicking a table photo changes Delete back to photo return")
        deletion.selectTrayForDeletion(deletionFirst)
        deletion.setSelection([placedID])
        check(deletion.selectedTrayForDeletion == nil, "marquee selection cancels the tray deletion target")
        deletion.selectTrayForDeletion(deletionFirst)
        deletion.setSelection([])
        check(deletion.selectedTrayForDeletion == nil, "empty-board click or Escape cancels the tray deletion target")
        deletion.selectTrayForDeletion(deletionFirst)
        deletion.selectTray(UUID())
        check(deletion.selectedTrayForDeletion == deletionFirst, "an unknown tray cannot change the deletion target")
        deletion.selectTray(deletionFirst)
        check(deletion.selectedTrayForDeletion == nil, "programmatic tray switching does not arm deletion")
        deletion.selectTrayForDeletion(deletionFirst)
        let deletionSecond = deletion.newTray()
        check(deletion.selectedTrayForDeletion == nil && deletion.activeTrayID == deletionSecond,
              "creating a tray does not leave the previous tray targeted for deletion")
        deletion.selectTrayForDeletion(deletionFirst)
        deletion.flushSave()
        check(TableModel(storageURL: root.appendingPathComponent("deletion.json")).selectedTrayForDeletion == nil,
              "the tray deletion target is transient and never restored on launch")

        deletion.selectTray(deletionSecond)
        await deletion.importURLs([a, c])
        deletion.place(c, x: 0.7, y: 0.6)
        let survivingSlide = deletion.selectedID!
        let album = deletion.newAlbum()
        deletion.updateAlbum(album) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(b, in: pocket)
        }
        deletion.placeAlbum(album)
        let albumsBeforeDeletion = deletion.albums
        deletion.isLit = true; deletion.pan = CGPoint(x: 17, y: 21); deletion.zoom = 1.6
        let deletionLightClock = deletion.lightStartedAt
        deletion.selectTrayForDeletion(deletionFirst)
        check(deletion.canDeleteSelection, "a selected tray enables the existing Delete command")
        deletion.deleteSelection()
        check(deletion.trays.map(\.id) == [deletionSecond] && deletion.activeTrayID == deletionSecond,
              "Delete removes the clicked tray and selects its right neighbor")
        check(deletion.layout.slides.map(\.id) == [survivingSlide]
            && !deletion.tableOrder.contains(placedID) && deletion.tableOrder.contains(survivingSlide),
              "deleting a tray removes its table films and layer entries while preserving other films")
        check(deletion.photos.map(\.url) == [a, c],
              "a shared photo is removed from the table without losing another tray's copy")
        check(deletion.albums == albumsBeforeDeletion && deletion.onTableAlbums.map(\.id) == [album],
              "tray deletion preserves independent album pages and their photos")
        check(deletion.selectedIDs.isEmpty && deletion.selectedTrayForDeletion == nil && !deletion.canDeleteSelection,
              "tray deletion clears its target and disables Delete until another explicit selection")
        check(deletion.isLit && deletion.lightStartedAt == deletionLightClock
            && deletion.pan == CGPoint(x: 17, y: 21) && deletion.zoom == 1.6,
              "tray deletion preserves the light and viewing position")
        deletion.deleteSelection()
        check(deletion.trays.map(\.id) == [deletionSecond] && deletion.layout.slides.map(\.id) == [survivingSlide],
              "repeated Delete cannot remove a neighboring tray or its films")
        deletion.flushSave()
        let afterDeletion = TableModel(storageURL: root.appendingPathComponent("deletion.json"))
        check(afterDeletion.trays == deletion.trays && afterDeletion.layout == deletion.layout
            && afterDeletion.albums == deletion.albums && afterDeletion.activeTrayID == deletionSecond,
              "deleted trays and their table films stay removed after restart")
        deletion.select(survivingSlide)
        deletion.deleteSelection()
        check(deletion.layout.slides.isEmpty && deletion.photos.map(\.url) == [a, c]
            && deletion.albums == albumsBeforeDeletion,
              "Delete on a selected photo still returns it to its original tray and order")

        let deletionThird = deletion.newTray(), deletionFourth = deletion.newTray()
        check(Set(deletion.trays.map(\.name)).count == deletion.trays.count,
              "new trays keep distinct names after an earlier tray is deleted")
        deletion.selectTrayForDeletion(deletionThird)
        deletion.deleteSelection()
        check(deletion.activeTrayID == deletionFourth && deletion.trays.map(\.id) == [deletionSecond, deletionFourth],
              "deleting a middle tray selects the right neighbor")
        deletion.selectTrayForDeletion(deletionFourth)
        deletion.deleteSelection()
        check(deletion.activeTrayID == deletionSecond && deletion.trays.count == 1,
              "deleting the rightmost tray selects the left neighbor")
        let inactiveTray = deletion.newTray()
        deletion.selectTray(deletionSecond)
        deletion.deleteTray(inactiveTray)
        check(deletion.activeTrayID == deletionSecond && deletion.trays.count == 1,
              "removing an inactive tray preserves the current tray")
        deletion.selectTrayForDeletion(deletionSecond)
        deletion.deleteTray(UUID())
        check(deletion.trays.count == 1 && deletion.selectedTrayForDeletion == deletionSecond,
              "an unknown tray deletion has no effect")
        deletion.deleteSelection()
        let replacementTray = deletion.activeTrayID
        check(deletion.trays.count == 1 && replacementTray != deletionSecond && deletion.photos.isEmpty,
              "deleting the last tray leaves a fresh empty import destination")
        check(deletion.albums == albumsBeforeDeletion, "deleting the last tray still preserves albums")
        deletion.flushSave()
        let emptyAfterDeletion = TableModel(storageURL: root.appendingPathComponent("deletion.json"))
        check(emptyAfterDeletion.activeTrayID == replacementTray && emptyAfterDeletion.photos.isEmpty,
              "the replacement empty tray survives restart")
        await deletion.importURLs([b, a])
        deletion.place(b, x: 0.4, y: 0.5)
        check(deletion.photos.map(\.url) == [a, b] && deletion.layout.slides.map(\.url) == [b],
              "importing and placing photos works after deleting the last tray")

        let pendingDeletion = TableModel(restore: false)
        let deletedDestination = pendingDeletion.activeTrayID
        let delayedDeletion = DeferredFile()
        let cancelledDrop = Task {
            await pendingDeletion.acceptDrop([delayedDeletion.provider], at: CGPoint(x: 100, y: 100),
                board: CGRect(x: 0, y: 0, width: 1000, height: 700))
        }
        let deletionDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !delayedDeletion.waiting {
            precondition(ProcessInfo.processInfo.systemUptime < deletionDeadline, "drop decoding did not start")
            try await Task.sleep(for: .milliseconds(1))
        }
        pendingDeletion.selectTrayForDeletion(deletedDestination)
        pendingDeletion.deleteSelection()
        delayedDeletion.finish(a)
        let acceptedAfterDeletion = await cancelledDrop.value
        check(!acceptedAfterDeletion && pendingDeletion.trays.count == 1
            && pendingDeletion.photos.isEmpty && pendingDeletion.layout.slides.isEmpty,
              "a drop completing after its destination was deleted cannot revive it or place photos")
        await pendingDeletion.importURLs([c], into: deletedDestination)
        check(pendingDeletion.photos.isEmpty && pendingDeletion.activeTrayID != deletedDestination && !pendingDeletion.isImporting,
              "an import targeting a deleted tray cannot spill into its replacement")
        for url in [a, b, c] { check(try Data(contentsOf: url) == image, "original file remains unchanged: \(url.lastPathComponent)") }
        print("\(count) tray checks passed.")
    }
}
