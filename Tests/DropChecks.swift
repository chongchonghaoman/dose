import AppKit
import UniformTypeIdentifiers
import LightTableCore

@main
struct DropChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Saved: Codable { var urls: [URL]; var layout: TableLayout; var label: String }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LightTableDropChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(description: label) }
            checks += 1; print("PASS \(label)")
        }
        func file(_ path: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url.standardizedFileURL
        }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let original = try file("originals/one.png", image)
        let model = TableModel(restore: false)
        await model.importURLs([original])
        let thumbnail = await PhotoStore.shared.thumbnail(original)!
        model.cacheThumbnail(thumbnail, for: original)
        let prepared = await model.preparePreview(original)
        let reused = await model.preparePreview(original)
        let originalLayout = model.layout, originalPhotos = model.photos
        let originalClock = model.lightStartedAt
        try check(model.transmissionEnabled, "transmitted light is permanently enabled")
        try check(model.layout == originalLayout && model.photos == originalPhotos &&
                  model.lightStartedAt == originalClock && model.preparedPreviews[original]?.source === prepared?.source,
                  "default transmission preserves layout, files, ignition clock and prepared previews")
        try check(model.thumbnails[original] === thumbnail, "placed photo can immediately reuse its tray thumbnail")
        try check(prepared != nil && reused?.source === prepared?.source && model.preparedPreviews[original] != nil,
                  "hover and repeated placement reuse the prepared preview")
        let point = CGPoint(x: 400, y: 300), board = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let provider = PhotoDrag.provider(for: model.photos[0])
        try check(provider.hasItemConformingToTypeIdentifier(PhotoDrag.contentType.identifier) &&
                  !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), "internal provider carries identity without a file export")
        for _ in 0..<5 {
            let accepted = await model.acceptDrop([provider], at: point, board: board)
            try check(accepted && model.photos.count == 1 && model.layout.slides.count == 1 && !model.isLit,
                      "repeated internal drop keeps one photo and lamp off")
        }
        let firstID = model.layout.slides[0].id
        model.isLit = true
        await model.acceptDrop([provider], at: CGPoint(x: 600, y: 400), board: board)
        try check(model.isLit && model.layout.slides[0].id == firstID && model.layout.slides[0].url == original,
                  "internal placement preserves lamp state, slide ID and source URL")
        await model.acceptDrop([provider], at: nil, board: nil)
        try check(model.photos.count == 1 && model.layout.slides.count == 1, "dropping onto tray does not import again")
        let filesBefore = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        await model.acceptDrop([PhotoDrag.provider(for: Photo(url: original))], at: point, board: board)
        let filesAfter = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        try check(filesBefore == filesAfter && (try Data(contentsOf: original)) == image, "internal drop creates no files and leaves original bytes intact")

        let external = try file("external/two.png", image)
        let externalProvider = NSItemProvider(object: external as NSURL)
        await model.acceptDrop([externalProvider], at: point, board: board)
        try check(model.photos.count == 2 && model.layout.slides.count == 2, "external file drop imports and places one photo")
        let nested = try file("folder/nested/three.png", image)
        let folder = nested.deletingLastPathComponent().deletingLastPathComponent()
        await model.acceptDrop([NSItemProvider(object: folder as NSURL)], at: point, board: board)
        try check(model.photos.count == 3 && model.layout.slides.count == 2, "external folder recursively fills tray without placing files")
        let unknown = try file("unknown/unknown.png", image)
        let rejected = await model.acceptDrop([PhotoDrag.provider(for: Photo(url: unknown))], at: point, board: board)
        try check(!rejected && model.photos.count == 3, "stale internal identity cannot import an arbitrary file")

        // Lighting is display state: toggling it must not reframe, rearrange,
        // re-import, or restart its animation when another slide is placed.
        let lighting = TableModel(restore: false)
        await lighting.importURLs([original, external])
        lighting.place(original, x: 0.24, y: 0.73)
        let litFirstID = lighting.selectedID!
        lighting.update(litFirstID) { $0.width = 0.48; $0.angle = 32 }
        lighting.place(external, x: 0.68, y: 0.31)
        lighting.zoom = 1.3
        lighting.loupeEnabled = true
        let beforeLightLayout = lighting.layout
        let beforeLightPhotos = lighting.photos
        let beforeLightSelection = lighting.selectedID
        lighting.lampBrightness = 0.35
        lighting.lampBrightness = 1.6
        try check(!lighting.isLit && lighting.lightStartedAt == nil && lighting.layout == beforeLightLayout && lighting.photos == beforeLightPhotos,
                  "brightness can be preset without lighting or rearranging photos")
        try check(!lighting.isLit && lighting.lightStartedAt == nil, "new table starts unlit with no illumination clock")
        let firstStartLowerBound = ProcessInfo.processInfo.systemUptime
        lighting.isLit = true
        guard let firstStart = lighting.lightStartedAt else { throw Failure(description: "opening lamp must start an illumination clock") }
        try check(firstStart >= firstStartLowerBound && firstStart <= ProcessInfo.processInfo.systemUptime,
                  "opening lamp uses a fresh monotonic illumination clock")
        try check(lighting.layout == beforeLightLayout && lighting.zoom == 1.3 && lighting.photos == beforeLightPhotos &&
                  lighting.selectedID == beforeLightSelection && lighting.loupeEnabled,
                  "opening lamp preserves coordinates, rotation, width, stacking, zoom, selection and tray photos")
        lighting.isLit = true
        try check(lighting.lightStartedAt == firstStart, "assigning an already lit lamp does not restart illumination")
        lighting.lampBrightness = 0.72
        try check(lighting.lightStartedAt == firstStart && lighting.layout == beforeLightLayout && lighting.photos == beforeLightPhotos,
                  "continuous dimming preserves the light clock and photo layout")
        try await Task.sleep(for: .milliseconds(5))
        lighting.place(original, x: 0.41, y: 0.56)
        try check(lighting.isLit && lighting.lightStartedAt == firstStart && lighting.photos == beforeLightPhotos && lighting.zoom == 1.3 &&
                  lighting.layout.slides.last?.id == litFirstID && lighting.layout.slides.last?.x == 0.41 && lighting.layout.slides.last?.y == 0.56,
                  "placing a photo while lit preserves the running light clock and global zoom")
        let beforeOffLayout = lighting.layout
        let beforeOffSelection = lighting.selectedID
        lighting.isLit = false
        try check(lighting.lightStartedAt == nil && lighting.layout == beforeOffLayout && lighting.zoom == 1.3 &&
                  lighting.photos == beforeLightPhotos && lighting.selectedID == beforeOffSelection && lighting.loupeEnabled,
                  "closing lamp clears only its clock and leaves layout, zoom, selection and tray photos unchanged")
        lighting.isLit = false
        try check(lighting.lightStartedAt == nil, "assigning an already dark lamp keeps its clock cleared")
        let secondStartLowerBound = ProcessInfo.processInfo.systemUptime
        lighting.isLit = true
        guard let secondStart = lighting.lightStartedAt else { throw Failure(description: "reopening lamp must restart illumination") }
        try check(secondStart > firstStart && secondStart >= secondStartLowerBound && secondStart <= ProcessInfo.processInfo.systemUptime &&
                  lighting.layout == beforeOffLayout && lighting.zoom == 1.3 && lighting.photos == beforeLightPhotos,
                  "reopening lamp starts a new light cycle without changing photos or framing")

        let preparing = TableModel(restore: false)
        let surfaceA = UUID(), surfaceB = UUID()
        preparing.beginLightPreparation(surfaceA); preparing.beginLightPreparation(surfaceB)
        preparing.isLit = true
        try check(preparing.lightStartedAt == nil, "lighting waits for all existing photo surfaces")
        preparing.finishLightPreparation(surfaceA)
        try check(preparing.lightStartedAt == nil, "first ready photo cannot ignite before the rest")
        preparing.finishLightPreparation(surfaceB)
        let synchronizedStart = preparing.lightStartedAt
        try check(synchronizedStart != nil, "last ready photo starts one shared illumination clock")
        preparing.beginLightPreparation(surfaceA); preparing.finishLightPreparation(surfaceA)
        try check(preparing.lightStartedAt == synchronizedStart, "adding a photo while lit does not replay ignition")
        preparing.isLit = false; preparing.beginLightPreparation(surfaceB); preparing.isLit = true
        preparing.isLit = false; preparing.finishLightPreparation(surfaceB)
        try check(!preparing.isLit && preparing.lightStartedAt == nil, "cancelling pending ignition cannot turn the lamp back on")

        let cacheRoot = root.appendingPathComponent("Caches", isDirectory: true)
        let cached = try file("Caches/com.apple.SwiftUI.Drag-\(UUID().uuidString)/one.png", image)
        var differentBytes = image
        differentBytes[differentBytes.count - 1] ^= 1
        let distinct = try file("Caches/com.apple.SwiftUI.Drag-\(UUID().uuidString)/one.png", differentBytes)
        let genuineSameName = try file("another-source/one.png", image)
        let missingOriginal = try file("Caches/com.apple.SwiftUI.Drag-\(UUID().uuidString)/orphan.png", image)
        var layout = TableLayout()
        _ = layout.place(original, x: 0.2, y: 0.2)
        let distinctID = layout.place(distinct, x: 0.25, y: 0.5)
        let cacheID = layout.place(cached, x: 0.72, y: 0.62)
        layout.update(cacheID) { $0.width = 0.23; $0.angle = 37 }
        let saved = Saved(urls: [original, cached, distinct, genuineSameName, missingOriginal], layout: layout, label: "Fixtures")
        let stored = root.appendingPathComponent("layout.json")
        let before = try JSONEncoder().encode(saved)
        try before.write(to: stored)
        let restored = TableModel(storageURL: stored, legacyCacheDirectory: cacheRoot)
        try check(restored.photos.count == 4 && restored.photos.contains(where: { $0.url == original }) &&
                  !restored.photos.contains(where: { $0.url == cached }), "byte-identical SwiftUI cache merges into original library photo")
        try check(restored.photos.contains(where: { $0.url == distinct }) &&
                  restored.photos.contains(where: { $0.url == genuineSameName }) &&
                  restored.photos.contains(where: { $0.url == missingOriginal }), "different bytes, real files and orphan caches remain distinct")
        let top = restored.layout.slides.last!
        try check(restored.layout.slides.count == 2 && restored.layout.slides.first?.id == distinctID &&
                  top.id == cacheID && top.url == original && top.x == 0.72 && top.y == 0.62 &&
                  top.width == 0.23 && top.angle == 37, "migration preserves topmost ID, coordinates, angle, width and stacking")
        let backups = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("layout.backup-v0.1.2-") }
        try check(backups.count == 1 && (try Data(contentsOf: backups[0])) == before, "migration writes an exact backup before replacing saved layout")
        let again = TableModel(storageURL: stored, legacyCacheDirectory: cacheRoot)
        let backupsAgain = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("layout.backup-v0.1.2-") }
        try check(again.photos.count == 4 && backupsAgain.count == 1 && again.layout == restored.layout, "migration is idempotent on the next launch")
        try check((try Data(contentsOf: original)) == image && fm.fileExists(atPath: cached.path), "migration neither edits original images nor deletes old cache files")
        let fitStorage = root.appendingPathComponent("fitted-layout.json")
        let fitModel = TableModel(restore: false, storageURL: fitStorage)
        for i in 0..<12 {
            let url = try file("fit/photo-\(i).png", image)
            fitModel.place(url, x: Double(i) - 6, y: Double(i % 3) * 4 - 4)
            fitModel.update(fitModel.selectedID!) { $0.width = 0.8; $0.angle = 15 }
        }
        fitModel.boardSize = CGSize(width: 840, height: 330)
        fitModel.isLit = true; fitModel.loupeEnabled = true; fitModel.lampBrightness = 1.4; fitModel.zoom = 1.5
        let fitPhotos = fitModel.photos, fitSelection = fitModel.selectedID, lightStart = fitModel.lightStartedAt
        fitModel.pan = CGPoint(x: -4500, y: 3400)
        fitModel.fitToWindow()
        try check(fitModel.pan == .zero && fitModel.worldSize == fitModel.boardSize,
                  "command zero returns from any distant camera and arranges around the visible table")
        try check(fitModel.zoom == 1 && fitModel.fitScale < 1 && fitModel.layout.slides.allSatisfy { $0.width == Slide.defaultWidth },
                  "fit resets individual and manual zoom while fitting all slides")
        try check(fitModel.photos == fitPhotos && fitModel.selectedID == fitSelection && fitModel.isLit && fitModel.loupeEnabled &&
                  fitModel.lampBrightness == 1.4 && fitModel.lightStartedAt == lightStart, "fit preserves library, selection, loupe, lamp and ignition clock")
        try check(fitModel.imageAspects.count == 12 && fitModel.imageAspects.values.allSatisfy { $0 == 1 },
                  "uncached photos use source geometry before a preview is ready")
        fitModel.flushSave()
        let fitRestored = TableModel(storageURL: fitStorage)
        try check(fitRestored.layout == fitModel.layout && fitRestored.fitScale == fitModel.fitScale, "fitted geometry and shared display scale survive relaunch")
        fitModel.clear()
        try check(fitModel.layout.slides.isEmpty && fitModel.fitScale == 1, "clearing the table restores default scale for new photos")
        let navigationStorage = root.appendingPathComponent("infinite-layout.json")
        let navigation = TableModel(restore: false, storageURL: navigationStorage)
        navigation.boardSize = CGSize(width: 1000, height: 700)
        navigation.place(original, x: -2, y: 3)
        let offscreen = navigation.layout.slides[0]
        try check(offscreen.x == -2 && offscreen.y == 3,
                  "photos can be placed beyond the initial table in both directions")
        navigation.zoomCanvas(by: 0.5, around: CGPoint(x: 200, y: 100))
        navigation.panBy(CGSize(width: -1600, height: 1200))
        try check(navigation.layout.slides[0] == offscreen,
                  "panning and zooming the camera never rewrite photo transforms")
        let beforeResize = navigation.screenPlacement(offscreen, aspect: 1)
        navigation.boardSize = CGSize(width: 1400, height: 950)
        try check(navigation.screenPlacement(offscreen, aspect: 1) == beforeResize,
                  "window resizing does not rescale or reposition the world")
        let target = CGPoint(x: 275, y: 380)
        let expected = navigation.normalizedWorldPoint(target)
        await navigation.acceptDrop([PhotoDrag.provider(for: Photo(url: original))], at: target,
                                    board: CGRect(origin: .zero, size: navigation.boardSize))
        let dropped = navigation.layout.slides[0]
        let screen = navigation.screenPlacement(dropped, aspect: 1)
        try check(abs(dropped.x - expected.x) < 1e-9 && abs(dropped.y - expected.y) < 1e-9 &&
                  abs(screen.x - target.x) < 1e-9 && abs(screen.y - target.y) < 1e-9,
                  "drop after panning and zoom lands at its exact screen location")
        navigation.flushSave()
        let navigationRestored = TableModel(storageURL: navigationStorage)
        try check(navigationRestored.layout == navigation.layout && navigationRestored.viewport == navigation.viewport &&
                  navigationRestored.worldSize == navigation.worldSize,
                  "offscreen layout and viewport survive relaunch without clamping")
        navigation.fitToWindow()
        try check(navigation.pan == .zero && navigation.zoom == 1 && navigation.layout.slides[0].width == Slide.defaultWidth &&
                  navigation.layout.slides[0].x > 0 && navigation.layout.slides[0].x < 1,
                  "command zero arranges distant photos at default size and returns to the global view")
        print("\(checks) drop checks passed.")
    }
}
