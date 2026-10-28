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
        check(Set(model.slideshowOrder) == Set([a, c]) && model.slideshowOrder.count == 2,
              "slideshow includes shared-canvas photos without duplicating selected-tray membership")
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
        check(emptyRestored.slideshowMode && Set(emptyRestored.slideshowOrder) == Set([a]),
              "an empty selected tray can still play a photo already on the shared canvas")
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
        deletion.deleteSelection()
        check(deletion.trays.count == 1 && deletion.photos.map(\.url) == [a, b] && !deletion.canDeleteSelection,
              "Delete after importing a folder cannot delete its default active tray")
        deletion.place(a, x: 0.2, y: 0.3)
        let placedID = deletion.selectedID!
        deletion.selectTray(deletionFirst)
        deletion.deleteSelection()
        check(deletion.selectedTrayPhoto == nil && deletion.selectedIDs.isEmpty && !deletion.canDeleteSelection
            && deletion.trays.count == 1 && deletion.layout.slides.map(\.id) == [placedID],
              "clicking the active tray clears photo selection and Delete leaves the whole tray intact")
        deletion.selectTrayPhoto(b, in: deletionFirst)
        check(deletion.selectedTrayPhoto?.trayID == deletionFirst && deletion.selectedTrayPhoto?.url == b
            && deletion.selectedIDs.isEmpty && deletion.canDeleteSelection,
              "clicking a tray photo targets that individual photo for Delete")
        deletion.select(placedID)
        check(deletion.selectedTrayPhoto == nil && deletion.selectedID == placedID,
              "clicking a table photo changes Delete back to photo return")
        deletion.selectTrayPhoto(b, in: deletionFirst)
        deletion.setSelection([placedID])
        check(deletion.selectedTrayPhoto == nil, "marquee selection cancels the tray photo deletion target")
        deletion.selectTrayPhoto(b, in: deletionFirst)
        deletion.setSelection([])
        check(deletion.selectedTrayPhoto == nil && !deletion.canDeleteSelection,
              "empty-board click or Escape cancels the tray photo deletion target")
        deletion.selectTrayPhoto(b, in: deletionFirst)
        deletion.selectTray(UUID())
        check(deletion.selectedTrayPhoto?.url == b, "an unknown tray cannot change the photo deletion target")
        deletion.selectTray(deletionFirst)
        check(deletion.selectedTrayPhoto == nil && !deletion.canDeleteSelection,
              "clicking the same tray again cancels its photo selection without arming tray deletion")
        deletion.selectTrayPhoto(b, in: deletionFirst)
        let deletionSecond = deletion.newTray()
        check(deletion.selectedTrayPhoto == nil && deletion.activeTrayID == deletionSecond,
              "creating a tray cancels the previous tray photo selection")
        deletion.selectTray(deletionFirst)
        deletion.selectTrayPhoto(b, in: deletionFirst)
        deletion.flushSave()
        check(TableModel(storageURL: root.appendingPathComponent("deletion.json")).selectedTrayPhoto == nil,
              "the tray photo deletion target is transient and never restored on launch")

        deletion.selectTray(deletionSecond)
        check(deletion.selectedTrayPhoto == nil && !deletion.canDeleteSelection,
              "switching trays cancels the previous photo target")
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
        deletion.selectTray(deletionFirst)
        deletion.deleteSelection()
        check(deletion.trays.count == 2 && deletion.layout.slides.count == 2 && !deletion.canDeleteSelection,
              "Delete with only a tray tab active cannot remove that tray or its films")
        deletion.deleteTray(deletionFirst)
        check(deletion.trays.map(\.id) == [deletionSecond] && deletion.activeTrayID == deletionSecond,
              "explicit tray deletion removes the clicked tray and selects its right neighbor")
        check(deletion.layout.slides.map(\.id) == [survivingSlide]
            && !deletion.tableOrder.contains(placedID) && deletion.tableOrder.contains(survivingSlide),
              "deleting a tray removes its table films and layer entries while preserving other films")
        check(deletion.photos.map(\.url) == [a, c],
              "a shared photo is removed from the table without losing another tray's copy")
        check(deletion.albums == albumsBeforeDeletion && deletion.onTableAlbums.map(\.id) == [album],
              "tray deletion preserves independent album pages and their photos")
        check(deletion.selectedIDs.isEmpty && deletion.selectedTrayPhoto == nil && !deletion.canDeleteSelection,
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
        deletion.selectTray(deletionThird)
        deletion.deleteTray(deletionThird)
        check(deletion.activeTrayID == deletionFourth && deletion.trays.map(\.id) == [deletionSecond, deletionFourth],
              "deleting a middle tray selects the right neighbor")
        deletion.selectTray(deletionFourth)
        deletion.deleteTray(deletionFourth)
        check(deletion.activeTrayID == deletionSecond && deletion.trays.count == 1,
              "deleting the rightmost tray selects the left neighbor")
        let inactiveTray = deletion.newTray()
        deletion.selectTray(deletionSecond)
        deletion.deleteTray(inactiveTray)
        check(deletion.activeTrayID == deletionSecond && deletion.trays.count == 1,
              "removing an inactive tray preserves the current tray")
        deletion.selectTrayPhoto(a, in: deletionSecond)
        deletion.deleteTray(UUID())
        check(deletion.trays.count == 1 && deletion.selectedTrayPhoto?.url == a,
              "an unknown tray deletion has no effect")
        deletion.deleteTray(deletionSecond)
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
        pendingDeletion.deleteTray(deletedDestination)
        delayedDeletion.finish(a)
        let acceptedAfterDeletion = await cancelledDrop.value
        check(!acceptedAfterDeletion && pendingDeletion.trays.count == 1
            && pendingDeletion.photos.isEmpty && pendingDeletion.layout.slides.isEmpty,
              "a drop completing after its destination was deleted cannot revive it or place photos")
        await pendingDeletion.importURLs([c], into: deletedDestination)
        check(pendingDeletion.photos.isEmpty && pendingDeletion.activeTrayID != deletedDestination && !pendingDeletion.isImporting,
              "an import targeting a deleted tray cannot spill into its replacement")

        let keyboardStorage = root.appendingPathComponent("keyboard-photo-deletion.json")
        let keyboard = TableModel(restore: false, storageURL: keyboardStorage)
        await keyboard.importURLs([a, b])
        let keyboardFirst = keyboard.activeTrayID
        let keyboardSecond = keyboard.newTray()
        await keyboard.importURLs([a, c])
        keyboard.selectTray(keyboardFirst)
        keyboard.place(a, x: 0.2, y: 0.3)
        let keyboardASlide = keyboard.selectedID!
        keyboard.place(b, x: 0.6, y: 0.7)
        let keyboardBSlide = keyboard.selectedID!
        let keyboardAlbum = keyboard.newAlbum()
        keyboard.updateAlbum(keyboardAlbum) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(a, in: pocket)
        }
        let keyboardAlbums = keyboard.albums
        keyboard.setSelection([keyboardASlide, keyboardBSlide])
        let aAlias = a.deletingLastPathComponent().appendingPathComponent("./a.png")
        keyboard.selectTrayPhoto(aAlias, in: keyboardFirst)
        check(keyboard.selectedTrayPhoto?.url == a && keyboard.selectedIDs.isEmpty,
              "selecting a tray photo normalizes its URL and clears every table selection")
        keyboard.selectTrayPhoto(c, in: keyboardFirst)
        keyboard.selectTrayPhoto(a, in: UUID())
        keyboard.selectTrayPhoto(a, in: keyboardSecond)
        check(keyboard.selectedTrayPhoto?.trayID == keyboardFirst && keyboard.selectedTrayPhoto?.url == a,
              "missing photos, unknown trays and stale clicks from inactive trays cannot redirect Delete")
        keyboard.deleteSelection()
        check(keyboard.trays.first { $0.id == keyboardFirst }?.urls == [b]
            && keyboard.layout.slides.map(\.id) == [keyboardBSlide]
            && !keyboard.tableOrder.contains(keyboardASlide),
              "Delete on a tray photo removes only that entry and its corresponding table film")
        check(keyboard.trays.first { $0.id == keyboardSecond }?.urls == [a, c]
            && keyboard.albums == keyboardAlbums && keyboard.trays.count == 2,
              "keyboard photo deletion preserves other trays, album photos and both tray identities")
        check(keyboard.selectedTrayPhoto == nil && keyboard.selectedIDs.isEmpty && !keyboard.canDeleteSelection,
              "keyboard photo deletion leaves no automatic next selection")
        keyboard.deleteSelection()
        check(keyboard.photos.map(\.url) == [b] && keyboard.layout.slides.map(\.id) == [keyboardBSlide]
            && keyboard.trays.count == 2,
              "repeated Delete cannot delete the next photo, its film or a tray")
        keyboard.flushSave()
        let keyboardRestored = TableModel(storageURL: keyboardStorage)
        check(keyboardRestored.trays == keyboard.trays && keyboardRestored.layout == keyboard.layout
            && keyboardRestored.albums == keyboardAlbums && !keyboardRestored.canDeleteSelection,
              "keyboard deletion persists while selection never restores")
        keyboard.select(keyboardBSlide)
        keyboard.deleteSelection()
        check(keyboard.layout.slides.isEmpty && keyboard.photos.map(\.url) == [b],
              "Delete on a table film still returns it without deleting its tray photo")
        keyboard.selectTrayPhoto(b, in: keyboardFirst)
        keyboard.deleteSelection()
        check(keyboard.photos.isEmpty && keyboard.activeTrayID == keyboardFirst && keyboard.trays.count == 2,
              "Delete on the last tray photo leaves its empty tray available")
        keyboard.selectTray(keyboardSecond)
        keyboard.selectTrayPhoto(c, in: keyboardSecond)
        keyboard.selectTrayPhoto(a, in: keyboardSecond)
        check(keyboard.selectedTrayPhoto?.url == a,
              "clicking another tray photo replaces the previous single-photo selection")
        keyboard.deleteTray(keyboardSecond)
        check(keyboard.selectedTrayPhoto == nil && !keyboard.canDeleteSelection && keyboard.activeTrayID == keyboardFirst,
              "explicit tray deletion clears any selected photo from that tray")

        let singlePhotoStorage = root.appendingPathComponent("single-photo-deletion.json")
        let singlePhoto = TableModel(restore: false, storageURL: singlePhotoStorage)
        await singlePhoto.importURLs([a, b])
        let singlePhotoFirstTray = singlePhoto.activeTrayID
        let singlePhotoSecondTray = singlePhoto.newTray()
        await singlePhoto.importURLs([a, c])
        singlePhoto.selectTray(singlePhotoFirstTray)
        singlePhoto.place(a, x: 0.25, y: 0.35)
        let aSlideID = singlePhoto.selectedID!
        singlePhoto.place(b, x: 0.65, y: 0.55)
        let bSlideID = singlePhoto.selectedID!
        let singlePhotoAlbum = singlePhoto.newAlbum()
        singlePhoto.updateAlbum(singlePhotoAlbum) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(a, in: pocket)
        }
        singlePhoto.setSelection([aSlideID, bSlideID])
        singlePhoto.deletePhoto(a, fromTray: singlePhotoFirstTray)
        check(singlePhoto.trays.first { $0.id == singlePhotoFirstTray }?.urls == [b]
            && singlePhoto.layout.slides.map(\.url) == [b],
              "deleting from one tray removes that entry and its matching table slide")
        check(!singlePhoto.tableOrder.contains(aSlideID) && singlePhoto.selectedIDs == [bSlideID],
              "single-photo deletion removes only its layer order and preserves other table selection")
        check(singlePhoto.trays.first { $0.id == singlePhotoSecondTray }?.urls == [a, c]
            && singlePhoto.albums.first { $0.id == singlePhotoAlbum }?.pockets.contains { $0.url == a } == true,
              "single-photo deletion preserves copies in other trays and album pages")
        check(singlePhoto.allPhotos.contains { $0.url == a },
              "a photo remains in the shared library when another tray or album still references it")
        singlePhoto.removeSelected()
        check(singlePhoto.layout.slides.isEmpty
            && singlePhoto.trays.first { $0.id == singlePhotoFirstTray }?.urls == [b]
            && singlePhoto.photos.map(\.url) == [b],
              "deleting a table photo still keeps it in its original tray")
        singlePhoto.flushSave()
        let singlePhotoRestored = TableModel(storageURL: singlePhotoStorage)
        check(singlePhotoRestored.activeTrayID == singlePhotoFirstTray
            && singlePhotoRestored.layout.slides.isEmpty
            && singlePhotoRestored.trays.first { $0.id == singlePhotoFirstTray }?.urls == [b]
            && singlePhotoRestored.trays.first { $0.id == singlePhotoSecondTray }?.urls == [a, c]
            && singlePhotoRestored.albums.first { $0.id == singlePhotoAlbum }?.pockets.contains { $0.url == a } == true,
              "single-photo deletion and unaffected references survive restart")
        singlePhoto.place(b, x: 0.4, y: 0.5)
        singlePhoto.selectTrayPhoto(b, in: singlePhotoFirstTray)
        let singlePhotoLayout = singlePhoto.layout, singlePhotoTrays = singlePhoto.trays
        singlePhoto.deletePhoto(c, fromTray: singlePhotoFirstTray)
        singlePhoto.deletePhoto(b, fromTray: UUID())
        check(singlePhoto.layout == singlePhotoLayout && singlePhoto.trays == singlePhotoTrays
            && singlePhoto.selectedTrayPhoto?.trayID == singlePhotoFirstTray && singlePhoto.selectedTrayPhoto?.url == b,
              "unknown tray or missing photo cannot delete table films or change the deletion target")
        singlePhoto.selectTray(singlePhotoSecondTray)
        singlePhoto.selectTrayPhoto(c, in: singlePhotoSecondTray)
        let bAlias = b.deletingLastPathComponent().appendingPathComponent("./b.png")
        singlePhoto.deletePhoto(bAlias, fromTray: singlePhotoFirstTray)
        check(singlePhoto.activeTrayID == singlePhotoSecondTray
            && singlePhoto.trays.first { $0.id == singlePhotoFirstTray }?.urls.isEmpty == true
            && singlePhoto.trays.first { $0.id == singlePhotoSecondTray }?.urls == [a, c]
            && singlePhoto.layout.slides.isEmpty,
              "a captured tray target survives switching and deleting its last photo preserves the empty tray")
        check(singlePhoto.selectedIDs.isEmpty && singlePhoto.selectedTrayPhoto == nil
            && !singlePhoto.canDeleteSelection && singlePhoto.fitScale == 1,
              "single-photo deletion clears stale deletion targets and resets an empty table scale")
        singlePhoto.deleteSelection()
        check(singlePhoto.trays.count == 2,
              "Delete after single-photo deletion cannot accidentally remove the active tray")
        singlePhoto.place(a, x: 0.3, y: 0.4)
        let remainingLayout = singlePhoto.layout, remainingSelection = singlePhoto.selectedIDs
        singlePhoto.deletePhoto(c, fromTray: singlePhotoSecondTray)
        check(singlePhoto.photos.map(\.url) == [a] && singlePhoto.layout == remainingLayout
            && singlePhoto.selectedIDs == remainingSelection && !singlePhoto.allPhotos.contains { $0.url == c },
              "deleting a tray-only photo preserves other table films and removes its unused library entry")
        for url in [a, b, c] {
            check(try Data(contentsOf: url) == image, "single-photo deletion leaves original unchanged: \(url.lastPathComponent)")
        }
        let batch = TableModel(restore: false, storageURL: root.appendingPathComponent("batch.json"))
        await batch.importURLs([a, b, c])
        let batchFirst = batch.activeTrayID
        let batchOther = batch.newTray()
        await batch.importURLs([a, b])
        batch.selectTray(batchFirst)
        batch.beginTrayPhotoSelection(a, in: batchFirst)
        check(batch.isSelectingTrayPhotos && batch.selectedTrayPhotos == [TrayPhotoSelection(trayID: batchFirst, url: a)],
              "multiselect begins with the context photo checked")
        batch.selectTrayPhoto(b, in: batchFirst)
        check(batch.selectedTrayPhotos.count == 2 && batch.canDeleteSelection && batch.selectedTrayPhoto == nil,
              "clicking another tray photo extends the batch selection")
        batch.beginTrayPhotoSelection(a, in: batchFirst)
        check(batch.selectedTrayPhotos.count == 2, "re-entering multiselect preserves existing checks")
        batch.selectTrayPhoto(a, in: batchFirst)
        batch.selectTrayPhoto(b, in: batchFirst)
        batch.deleteSelection()
        check(batch.isSelectingTrayPhotos && batch.selectedTrayPhotos.isEmpty && !batch.canDeleteSelection
            && batch.photos.map(\.url) == [a, b, c], "an empty selection cannot delete photos or the tray")
        batch.beginTrayPhotoSelection(b, in: batchOther)
        check(batch.selectedTrayPhotos.isEmpty, "another tray cannot enter the current batch")
        batch.selectTrayPhoto(a, in: batchFirst)
        batch.selectTrayPhoto(b, in: batchFirst)
        batch.selectTray(batchOther)
        check(!batch.isSelectingTrayPhotos && batch.selectedTrayPhotos.isEmpty,
              "switching trays clears the whole batch")
        batch.deleteSelection()
        check(batch.photos.map(\.url) == [a, b], "Delete after a tray switch does not target the previous batch")
        batch.selectTray(batchFirst)
        batch.beginTrayPhotoSelection(a, in: batchFirst)
        batch.setSelection([])
        check(!batch.isSelectingTrayPhotos && batch.selectedTrayPhotos.isEmpty,
              "Escape or canvas selection exits tray multiselect")
        batch.place(a, x: 0.2, y: 0.3)
        batch.place(b, x: 0.4, y: 0.3)
        batch.place(c, x: 0.6, y: 0.3)
        batch.beginTrayPhotoSelection(a, in: batchFirst)
        batch.selectTrayPhoto(b, in: batchFirst)
        check(batch.selectedIDs.isEmpty, "entering tray multiselect clears canvas deletion targets")
        batch.deleteSelection()
        check(batch.photos.map(\.url) == [c] && batch.layout.slides.map(\.url) == [c],
              "batch deletion removes exactly the selected members and matching canvas films")
        check(batch.trays.first { $0.id == batchOther }?.urls == [a, b],
              "batch deletion preserves matching members in other trays")
        check(!batch.isSelectingTrayPhotos && batch.selectedTrayPhotos.isEmpty && !batch.canDeleteSelection,
              "successful batch deletion exits selection without selecting a neighboring photo")
        batch.flushSave()
        let batchRestored = TableModel(storageURL: root.appendingPathComponent("batch.json"))
        check(batchRestored.trays == batch.trays && batchRestored.layout == batch.layout,
              "batch deletion and surviving canvas placements persist")
        batch.beginTrayPhotoSelection(c, in: batchFirst)
        batch.cancelTrayPhotoSelection()
        check(batch.photos.map(\.url) == [c] && !batch.canDeleteSelection,
              "cancel leaves all remaining photos intact")
        batch.beginTrayPhotoSelection(c, in: batchFirst)
        batch.deleteSelection()
        check(batch.photos.isEmpty && batch.trays.count == 2 && batch.layout.slides.isEmpty,
              "deleting every selected photo preserves an empty import tray")
        for url in [a, b, c] { check(try Data(contentsOf: url) == image, "original file remains unchanged: \(url.lastPathComponent)") }
        print("\(count) tray checks passed.")
    }
}
