import AppKit
import UniformTypeIdentifiers
import ImageIO
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
        try check(TablePreviewSizing.maxPixel(size: CGSize(width: 110, height: 74), displayScale: 2) == 256,
                  "small Retina table photos request 256 pixels instead of 2200")
        try check(TablePreviewSizing.maxPixel(size: CGSize(width: 110, height: 170), displayScale: 2) == 384,
                  "portrait previews use their displayed long edge")
        try check(TablePreviewSizing.maxPixel(size: CGSize(width: 200, height: 130), displayScale: 1) == 256 &&
                  TablePreviewSizing.maxPixel(size: CGSize(width: 200, height: 130), displayScale: 2) == 512,
                  "moving to a Retina display requests sufficient image pixels")
        try check(TablePreviewSizing.maxPixel(size: CGSize(width: 250, height: 160), displayScale: 2) == 512 &&
                  TablePreviewSizing.maxPixel(size: CGSize(width: 251, height: 160), displayScale: 2) == 512,
                  "minor size changes reuse the same preview bucket")
        try check(TablePreviewSizing.maxPixel(size: CGSize(width: 257, height: 170), displayScale: 2) == 768 &&
                  TablePreviewSizing.maxPixel(size: CGSize(width: 2000, height: 1500), displayScale: 2) == 2200,
                  "zooming upgrades preview size up to the existing full-resolution limit")
        try check(TablePreviewSizing.maxPixel(size: .zero, displayScale: 2) == 256 &&
                  TablePreviewSizing.maxPixel(size: CGSize(width: CGFloat.nan, height: 100), displayScale: 2) == 256 &&
                  TablePreviewSizing.maxPixel(size: CGSize(width: 200, height: 100), displayScale: .infinity) == 256,
                  "transient invalid geometry cannot generate unbounded requests")

        let previewFixture = root.appendingPathComponent("sizing.png")
        let pixels = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
            bytesPerRow: 2400 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(gray: 0.45, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let output = CGImageDestinationCreateWithURL(previewFixture as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, pixels.makeImage()!, nil)
        try check(CGImageDestinationFinalize(output), "create a full-size fixture for preview separation checks")
        let originalFixture = try Data(contentsOf: previewFixture)
        let sizingModel = TableModel(restore: false)
        let small = await sizingModel.prepareTablePreview(previewFixture, maxPixel: 256)
        let repeatedSmall = await sizingModel.prepareTablePreview(previewFixture, maxPixel: 256)
        try check(small?.source.width == 256 && small?.source === repeatedSmall?.source,
                  "table loading decodes its requested size and reuses it")
        try check(small.map { [$0.source, $0.dark, $0.lit, $0.flare, $0.boosted].allSatisfy { max($0.width, $0.height) <= 256 } } == true,
                  "all five table optical layers stay within the requested pixel budget")
        try check(sizingModel.preparedPreviews[previewFixture] == nil,
                  "loading table previews does not prepare or impersonate full-resolution loupe previews")
        let large = await sizingModel.prepareTablePreview(previewFixture, maxPixel: 768)
        let reduced = await sizingModel.prepareTablePreview(previewFixture, maxPixel: 256)
        try check(large?.source.width == 768 && reduced?.source === large?.source,
                  "zoom upgrades the table and shrinking reuses its existing sharper image")
        let full = await sizingModel.preparePreview(previewFixture)
        try check(full?.source.width == 2200 && sizingModel.preparedTablePreviews[previewFixture]?.source === large?.source,
                  "loupe still gets 2200 pixels without replacing the table-sized image")
        let concurrent = TableModel(restore: false)
        async let a = concurrent.prepareTablePreview(previewFixture, maxPixel: 384)
        async let b = concurrent.prepareTablePreview(previewFixture, maxPixel: 384)
        let pair = await (a, b)
        try check(pair.0 != nil && pair.0?.source === pair.1?.source,
                  "concurrent consumers of one URL and size share their preview")
        try check(try Data(contentsOf: previewFixture) == originalFixture,
                  "display-sized rendering never rewrites the original image")

        let startupStorage = root.appendingPathComponent("startup-layout.json")
        let startupWriter = TableModel(restore: false, storageURL: startupStorage)
        let startupAlbumPhoto = try file("startup/album.png", image)
        let startupTrayPhoto = try file("startup/tray-only.png", image)
        let startupOffTablePhoto = try file("startup/off-table-album.png", image)
        startupWriter.place(previewFixture, x: 0.3, y: 0.4)
        let looseSurface = startupWriter.layout.slides[0].id
        let startupAlbumID = startupWriter.newAlbum()
        startupWriter.updateAlbum(startupAlbumID) { page in
            let same = page.add(.film135)!
            page.setPhoto(previewFixture, in: same)
            let other = page.add(.film135)!
            page.setPhoto(startupAlbumPhoto, in: other)
        }
        startupWriter.placeAlbum(startupAlbumID)
        let offTableAlbumID = startupWriter.newAlbum()
        startupWriter.updateAlbum(offTableAlbumID) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(startupOffTablePhoto, in: pocket)
        }
        await startupWriter.importURLs([startupTrayPhoto])
        startupWriter.flushSave()
        let savedStartupBytes = try Data(contentsOf: startupStorage)
        let startup = TableModel(storageURL: startupStorage)
        try check(startup.isPreparingStartup && startup.startupTotal == 2 && startup.startupCompleted == 0,
                  "restart prepares unique photos from loose films and on-table albums only")
        let albumSurfaces = startup.onTableAlbums.flatMap { $0.pockets.map(\.id) }
        startup.beginLightPreparation(looseSurface)
        for id in albumSurfaces { startup.beginLightPreparation(id) }
        async let firstPreparation: Void = startup.prepareStartup()
        async let repeatedPreparation: Void = startup.prepareStartup()
        _ = await (firstPreparation, repeatedPreparation)
        try check(startup.startupCompleted == 2 && startup.startupFailedURLs.isEmpty && startup.startupPhase == .finishing,
                  "duplicate startup consumers share one job and cannot finish before display surfaces")
        try check(startup.preparedPreviews[previewFixture]?.source.width == 2200 &&
                  startup.preparedPreviews[startupAlbumPhoto] != nil,
                  "restored loose and album photos have sharp loupe previews before entering")
        try check(startup.preparedPreviews[startupTrayPhoto] == nil && startup.preparedPreviews[startupOffTablePhoto] == nil,
                  "startup does not decode tray-only or off-table album photos at full resolution")
        startup.finishLightPreparation(looseSurface)
        try check(startup.isPreparingStartup, "startup still waits for restored album display surfaces")
        for id in albumSurfaces { startup.finishLightPreparation(id) }
        try check(!startup.isPreparingStartup, "last prepared surface releases the startup screen")
        startup.isLit = true
        try check(startup.lightStartedAt != nil, "lamp responds immediately after startup readiness")
        let startupFull = startup.preparedPreviews[previewFixture]
        await startup.prepareStartup()
        try check(startup.startupCompleted == 2 && !startup.isPreparingStartup &&
                  startup.preparedPreviews[previewFixture]?.source === startupFull?.source,
                  "reappearing windows do not restart preparation or replace the sharp cached image")
        try check(try Data(contentsOf: startupStorage) == savedStartupBytes &&
                  Data(contentsOf: previewFixture) == originalFixture,
                  "startup leaves saved arrangement and original photo bytes untouched")

        let brokenPhoto = try file("startup/broken.png", Data("not an image".utf8))
        let brokenStorage = root.appendingPathComponent("startup-failure.json")
        let brokenWriter = TableModel(restore: false, storageURL: brokenStorage)
        brokenWriter.place(brokenPhoto, x: 0.2, y: 0.3)
        brokenWriter.flushSave()
        let failedStartup = TableModel(storageURL: brokenStorage)
        let brokenSurface = failedStartup.layout.slides[0].id
        failedStartup.finishLightPreparation(brokenSurface)
        await failedStartup.prepareStartup()
        try check(failedStartup.startupPhase == .needsAttention && failedStartup.startupCompleted == 0 &&
                  failedStartup.startupFailedURLs == [brokenPhoto],
                  "unreadable photos show an explicit retry state instead of fake completion")
        let failedSkip = TableModel(storageURL: brokenStorage)
        failedSkip.finishLightPreparation(brokenSurface)
        await failedSkip.prepareStartup()
        failedSkip.continueStartup()
        try check(!failedSkip.isPreparingStartup && failedSkip.layout.slides.count == 1,
                  "explicit continue enters without deleting an unreadable photo or its layout")
        try image.write(to: brokenPhoto)
        await failedStartup.retryStartup()
        try check(failedStartup.startupCompleted == 1 && failedStartup.startupFailedURLs.isEmpty &&
                  failedStartup.startupAttempt == 1 && failedStartup.startupPhase == .finishing,
                  "retry refreshes surface tasks and waits for their replacement images")
        failedStartup.finishLightPreparation(brokenSurface)
        try check(!failedStartup.isPreparingStartup && failedStartup.preparedPreviews[brokenPhoto] != nil,
                  "recovering a source file makes the sharp image available before entry")

        let trayStorage = root.appendingPathComponent("startup-empty.json")
        let trayWriter = TableModel(restore: false, storageURL: trayStorage)
        await trayWriter.importURLs([startupTrayPhoto])
        trayWriter.flushSave()
        let emptyStartup = TableModel(storageURL: trayStorage)
        await emptyStartup.prepareStartup()
        try check(!emptyStartup.isPreparingStartup && emptyStartup.startupTotal == 0 && emptyStartup.preparedPreviews.isEmpty,
                  "a restored empty table opens immediately even when the tray has photos")
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
                  "fit-to-window arranges distant photos at default size and returns to the global view")
        let batchStorage = root.appendingPathComponent("batch-layout.json")
        let batch = TableModel(restore: false, storageURL: batchStorage)
        batch.boardSize = CGSize(width: 1000, height: 700)
        let batchB = try file("batch/two.png", image), batchC = try file("batch/three.png", image)
        for (index, url) in [original, batchB, batchC].enumerated() {
            batch.cacheThumbnail(thumbnail, for: url)
            batch.place(url, x: 0.2 + Double(index) * 0.7, y: 0.5)
        }
        let batchIDs = batch.layout.slides.map(\.id)
        let batchPhotos = batch.photos
        batch.isLit = true
        let batchClock = batch.lightStartedAt
        batch.loupeEnabled = false
        batch.select(batchIDs[0], showIndicator: false)
        try check(batch.selectedIDs == [batchIDs[0]] && batch.tableIDs.last == batchIDs[0] && !batch.showsSelection,
                  "ordinary dragging raises the photo and retains its Delete target without a blue border")
        batch.update(batchIDs[0]) { $0.angle = 10 }
        try check(!batch.showsSelection, "committing a dragged photo does not flash selection chrome back on")
        batch.select(batchIDs[0])
        try check(batch.showsSelection, "clicking the same photo after dragging restores explicit selection feedback")
        batch.loupeEnabled = true
        try check(!batch.showsSelection && batch.selectedIDs == [batchIDs[0]],
                  "loupe viewing hides selection chrome without losing the active photo")
        batch.loupeEnabled = false
        batch.select(batchIDs[0], showIndicator: false)
        batch.setSelection([batchIDs[0]])
        try check(batch.showsSelection, "marquee selection reveals the same photo even when its ID set is unchanged")
        batch.select(batchIDs[0]); batch.select(batchIDs[1], extending: true)
        try check(batch.selectedIDs == Set(batchIDs.prefix(2)), "command-click adds another photograph without clearing selection")
        try check(batch.showsSelection, "command multi-selection keeps its visible selection feedback")
        batch.select(batchIDs[0], extending: true)
        try check(batch.selectedIDs == [batchIDs[1]], "command-click toggles an already-selected photograph off")
        batch.select(batchIDs[1], extending: true)
        try check(batch.selectedIDs.isEmpty && batch.selectedID == nil, "toggling the last selected item clears the primary selection")
        let invalidID = UUID()
        batch.setSelection([batchIDs[0], batchIDs[1], invalidID])
        try check(batch.selectedIDs == Set(batchIDs.prefix(2)), "selection rejects stale or foreign identifiers")
        batch.select(batchIDs[2])
        try check(batch.selectedIDs == [batchIDs[2]], "plain selection replaces a previous multi-selection")
        batch.selectedID = nil
        try check(batch.selectedIDs.isEmpty, "legacy clear-selection action clears the complete set")
        let untouchedLayout = batch.layout
        batch.removeSelected()
        try check(batch.layout == untouchedLayout, "empty selection never removes a photograph")
        batch.zoom = 0.65; batch.pan = CGPoint(x: -60, y: 85)
        batch.update(batchIDs[0]) { $0.angle = 45 }
        let first = batch.layout.slides.first { $0.id == batchIDs[0] }!
        let firstPlacement = batch.screenPlacement(first, aspect: 1)
        batch.select(in: CGRect(x: firstPlacement.x - 2, y: firstPlacement.y - 2, width: 4, height: 4))
        try check(batch.selectedIDs == [batchIDs[0]], "marquee selects a rotated photograph after pan and camera zoom")
        let extent = (firstPlacement.width + firstPlacement.height) / (2 * sqrt(2.0))
        batch.select(in: CGRect(x: firstPlacement.x + extent - 4, y: firstPlacement.y + extent - 4, width: 2, height: 2))
        try check(batch.selectedIDs.isEmpty, "empty corners of a rotated bounding box are not mistaken for image pixels")
        let second = batch.layout.slides.first { $0.id == batchIDs[1] }!
        let secondPlacement = batch.screenPlacement(second, aspect: 1)
        let area = CGRect(x: firstPlacement.x - extent - 2, y: firstPlacement.y - extent - 2,
                          width: secondPlacement.x + secondPlacement.width / 2 - firstPlacement.x + extent + 4,
                          height: extent * 2 + 4)
        batch.select(in: area)
        try check(batch.selectedIDs == Set(batchIDs.prefix(2)), "marquee selects all intersecting photos and excludes a distant photo")
        batch.select(in: CGRect(x: area.maxX, y: area.maxY, width: -area.width, height: -area.height))
        try check(batch.selectedIDs == Set(batchIDs.prefix(2)), "reverse-direction marquee uses the same selection area")
        batch.select(in: .zero)
        try check(batch.selectedIDs.isEmpty, "zero-size marquee clears the previous selection safely")
        let batchAlbum = batch.newAlbum()
        batch.updateAlbum(batchAlbum) { page in
            let pocket = page.add(.film135)!
            page.setPhoto(original, in: pocket)
        }
        batch.placeAlbum(batchAlbum, at: CGPoint(x: 800, y: 400))
        let albumPockets = batch.albums[0].pockets
        batch.select(in: batch.albumFrame(batch.albums[0]))
        try check(batch.selectedIDs.contains(batchAlbum), "marquee treats an album page as a table item")
        batch.setSelection([batchIDs[0], batchIDs[1], batchAlbum])
        batch.removeSelected()
        try check(batch.layout.slides.map(\.id) == [batchIDs[2]], "batch removal keeps the unselected photograph in place")
        try check(batch.onTableAlbums.isEmpty && batch.albums[0].pockets == albumPockets,
                  "batch removal returns the entire album to the tray without deleting pockets")
        try check(batch.photos == batchPhotos && batch.isLit && batch.lightStartedAt == batchClock,
                  "batch removal preserves the library and lamp state")
        try check(batch.selectedIDs.isEmpty && !batch.tableIDs.contains(batchAlbum) &&
                  !batch.tableOrder.contains(batchIDs[0]), "batch removal clears selection and obsolete stacking references")
        batch.flushSave()
        let batchRestored = TableModel(storageURL: batchStorage)
        try check(batchRestored.layout == batch.layout && batchRestored.albums == batch.albums && batchRestored.photos == batchPhotos,
                  "batch removal persists while all library and album contents survive relaunch")
        try check(batchRestored.selectedIDs.isEmpty, "selection remains transient across relaunch")
        batch.select(batchIDs[2]); batch.removeSelected()
        try check(batch.layout.slides.isEmpty && batch.fitScale == 1 && batch.photos == batchPhotos,
                  "removing the final photograph resets layout scale but keeps the tray")
        for url in [original, batchB, batchC] {
            try check(Data(contentsOf: url) == image, "batch removal never deletes or changes source \(url.lastPathComponent)")
        }
        print("\(checks) drop checks passed.")
    }
}
