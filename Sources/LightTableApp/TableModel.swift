import AppKit
import LightTableEDR
import SwiftUI
import UniformTypeIdentifiers
import LightTableCore

struct PhotoTray: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var urls: [URL] = []
}

struct TrayPhotoSelection: Hashable {
    let trayID: UUID
    let url: URL
}

@MainActor
@Observable
final class TableModel {
    static let defaultLampBrightness = 1.0
    static let edrLampBrightness = LTEDRBrightness()
    private(set) var trays = [PhotoTray(name: "底栏 1")]
    private var selectedTrayID: UUID?
    private(set) var selectedTrayPhotos: Set<TrayPhotoSelection> = []
    private(set) var isSelectingTrayPhotos = false
    var selectedTrayPhoto: TrayPhotoSelection? {
        selectedTrayPhotos.count == 1 ? selectedTrayPhotos.first : nil
    }
    private var activeTrayIndex: Int { trays.firstIndex { $0.id == selectedTrayID } ?? 0 }
    var activeTrayID: UUID { trays[activeTrayIndex].id }
    // Existing tray actions read only the selected tray. The table stays shared.
    var photos: [Photo] {
        get { trays[activeTrayIndex].urls.map { Photo(url: $0) } }
        set { trays[activeTrayIndex].urls = Self.uniqueURLs(newValue.map(\.url)) }
    }
    var allPhotos: [Photo] {
        Self.uniqueURLs(trays.flatMap(\.urls) + layout.slides.map(\.url)
            + albums.flatMap { $0.pockets.compactMap(\.url) }).map { Photo(url: $0) }
    }
    var layout = TableLayout()
    var albums: [AlbumPage] = []
    var tableOrder: [UUID] = []
    var albumEditorPresented = false
    var editingAlbumID: UUID?
    private(set) var selectedIDs: Set<UUID> = []
    private var selectionIndicatorsVisible = true
    var showsSelection: Bool { selectionIndicatorsVisible && !loupeEnabled && !selectedIDs.isEmpty }
    // Compatibility for existing single-item actions. Selection is transient.
    var selectedID: UUID? {
        get { tableIDs.last { selectedIDs.contains($0) } }
        set { setSelection(newValue.map { [$0] } ?? []) }
    }
    // One clock for the panel, slides and loupe; placing a photo never restarts it.
    private(set) var lightStartedAt: TimeInterval?
    @ObservationIgnored private var preparingLightSurfaces = Set<UUID>()
    var isLit = false {
        didSet {
            guard isLit != oldValue else { return }
            lightStartedAt = isLit && preparingLightSurfaces.isEmpty ? ProcessInfo.processInfo.systemUptime : nil
        }
    }
    var loupeEnabled = false
    var slideshowMode = false
    var returnToPastMode = false
    var slideshowIndex = 0
    private(set) var slideshowOrder: [URL] = []
    var zoom = 1.0
    private(set) var fitScale = 1.0
    // fitScale preserves the existing packed layout; zoom belongs to the camera.
    var displayZoom: Double { fitScale }
    var pan = CGPoint.zero
    private(set) var referenceSize: CGSize?
    var boardSize = CGSize.zero {
        didSet {
            if referenceSize == nil, boardSize.width > 1, boardSize.height > 1 {
                referenceSize = boardSize
            }
        }
    }
    var worldSize: CGSize { referenceSize ?? (boardSize.width > 1 ? boardSize : CGSize(width: 1180, height: 550)) }
    var viewport: TableViewport { TableViewport(scale: zoom, offsetX: pan.x, offsetY: pan.y) }
    private(set) var imageAspects: [URL: Double] = [:]
    private var ordinaryLampBrightness = TableModel.defaultLampBrightness
    private(set) var edrBrightness = TableModel.edrLampBrightness
    var backlightEDREnabled = false
    // Each mode retains its own setting for this session. The slideshow can
    // use the EDR setting without changing the table's current mode.
    var lampBrightnessDefault: Double {
        backlightEDREnabled ? Self.edrLampBrightness : Self.defaultLampBrightness
    }
    var lampBrightness: Double {
        get { backlightEDREnabled ? edrBrightness : ordinaryLampBrightness }
        set {
            if backlightEDREnabled {
                guard newValue.isFinite else { return }
                edrBrightness = min(1.6, max(0.1, newValue))
            } else {
                ordinaryLampBrightness = newValue
            }
        }
    }
    let transmissionEnabled = true
    var sourceLabel: String {
        get { trays[activeTrayIndex].name }
        set { trays[activeTrayIndex].name = newValue }
    }
    var isImporting = false
    var message: String?
    private(set) var thumbnails: [URL: CGImage] = [:]
    // Full-resolution previews remain reserved for the loupe.
    private(set) var preparedPreviews: [URL: PhotoPreview] = [:]
    enum StartupPhase { case preparing, finishing, needsAttention, ready }
    private(set) var startupPhase: StartupPhase = .ready
    private(set) var startupTotal = 0
    private(set) var startupCompleted = 0
    private(set) var startupFailedURLs: [URL] = []
    private(set) var startupAttempt = 0
    struct SurfaceRequest: Hashable { let preview: TablePreviewRequest; let attempt: Int }
    var isPreparingStartup: Bool { startupPhase != .ready }
    @ObservationIgnored private var startupURLs: [URL] = []
    @ObservationIgnored private var startupSurfaceIDs = Set<UUID>()
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    private(set) var preparedTablePreviews: [URL: PhotoPreview] = [:]
    private var tablePreviewSizes: [URL: Int] = [:]
    private var tablePreviewOrder: [URL] = []
    @ObservationIgnored private var tablePreviewTasks: [TablePreviewRequest: (id: UUID, task: Task<PhotoPreview?, Never>)] = [:]
    private var thumbnailOrder: [URL] = []
    private var previewOrder: [URL] = []
    @ObservationIgnored private var previewTasks: [URL: Task<PhotoPreview?, Never>] = [:]
    private let storageURL: URL?
    private var saveTask: Task<Void, Never>?
    private var importsInFlight = 0

    init(restore: Bool = true, storageURL overrideURL: URL? = nil, legacyCacheDirectory: URL? = nil) {
        storageURL = overrideURL ?? (restore ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("OurLightTable/layout-v1.json") : nil)
        if restore, let storageURL, let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            var restored = saved
            let aliases = PhotoLibrary.legacyDragAliases(in: saved.urls + (saved.trays ?? []).flatMap(\.urls)
                + saved.layout.slides.map(\.url), cacheDirectory: legacyCacheDirectory)
            if !aliases.isEmpty {
                do {
                    // Back up the exact previous bytes before any migration can be saved.
                    let backup = storageURL.deletingPathExtension().appendingPathExtension("backup-v0.1.2-\(UUID().uuidString).json")
                    try data.write(to: backup, options: .atomic)
                    restored = try Self.remapping(saved, aliases: aliases)
                } catch {
                    message = "旧拖片记录暂时无法修复：\(error.localizedDescription)"
                }
            }
            layout = restored.layout.sanitized()
            var pageIDs = Set<UUID>()
            albums = (restored.albums ?? []).filter { pageIDs.insert($0.id).inserted }.map { $0.sanitized() }
            tableOrder = restored.tableOrder ?? []
            if let width = restored.worldWidth, let height = restored.worldHeight,
               width.isFinite, height.isFinite, width > 1, height > 1 {
                referenceSize = CGSize(width: width, height: height)
            }
            if let camera = restored.viewport {
                let valid = TableViewport(scale: camera.scale, offsetX: camera.offsetX, offsetY: camera.offsetY)
                zoom = min(8, max(0.05, valid.scale)); pan = CGPoint(x: valid.offsetX, y: valid.offsetY)
            }
            if let scale = restored.fitScale, scale.isFinite, scale > 0, scale <= 1 { fitScale = scale }
            for slide in layout.slides where !PhotoLibrary.supported(slide.url) { layout.remove(slide.id) }
            if let savedTrays = restored.trays, !savedTrays.isEmpty {
                var ids = Set<UUID>()
                trays = savedTrays.map { tray in
                    var tray = tray
                    if !ids.insert(tray.id).inserted { tray.id = UUID(); ids.insert(tray.id) }
                    tray.urls = Self.uniqueURLs(tray.urls).filter { PhotoLibrary.supported($0) }
                    return tray
                }
                selectedTrayID = restored.activeTrayID
            } else {
                // A legacy library becomes one tray, including table/album-only references.
                let urls = Self.uniqueURLs(restored.urls + layout.slides.map(\.url)
                    + albums.flatMap { $0.pockets.compactMap(\.url) }).filter { PhotoLibrary.supported($0) }
                trays = [PhotoTray(name: restored.label, urls: urls)]
            }
            selectedTrayID = activeTrayID
            if !aliases.isEmpty && message == nil { persist(to: storageURL) }
            // Prepare only the restored table, never the entire imported library.
            var startupSeen = Set<URL>()
            startupURLs = (layout.slides.map(\.url) + onTableAlbums.flatMap { $0.pockets.compactMap(\.url) })
                .filter { startupSeen.insert($0).inserted }
            startupSurfaceIDs = Set(layout.slides.map(\.id) + onTableAlbums.flatMap {
                $0.pockets.filter { $0.url != nil }.map(\.id)
            })
            startupTotal = startupURLs.count
            if startupTotal > 0 { startupPhase = .preparing }
        }
    }

    var selected: Slide? { layout.slides.first { $0.id == selectedID } }

    func beginLightPreparation(_ id: UUID) { preparingLightSurfaces.insert(id) }

    func finishLightPreparation(_ id: UUID) {
        preparingLightSurfaces.remove(id)
        startupSurfaceIDs.remove(id)
        finishStartupIfReady()
        if isLit && lightStartedAt == nil && preparingLightSurfaces.isEmpty {
            lightStartedAt = ProcessInfo.processInfo.systemUptime
        }
    }

    /// One model-owned job survives individual window tasks being cancelled.
    /// Await one photo at a time so restoring a table cannot fan out decodes.
    func prepareStartup() async {
        if let task = startupTask { await task.value; return }
        guard startupPhase == .preparing else { return }
        let pending = startupURLs.filter { preparedPreviews[$0] == nil }
        startupCompleted = startupTotal - pending.count
        startupFailedURLs = []
        let task = Task { [weak self] in
            for url in pending {
                guard let self else { return }
                if await self.preparePreview(url) != nil { self.startupCompleted += 1 }
                else { self.startupFailedURLs.append(url) }
                await Task.yield()
            }
            guard let self else { return }
            self.startupPhase = self.startupFailedURLs.isEmpty ? .finishing : .needsAttention
            self.finishStartupIfReady()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    func retryStartup() async {
        guard startupPhase == .needsAttention, startupTask == nil else { return }
        // Re-run failed table surfaces too, rather than leaving their placeholders
        // in place after the full-size image becomes available again.
        startupSurfaceIDs = Set(layout.slides.map(\.id) + onTableAlbums.flatMap {
            $0.pockets.filter { $0.url != nil }.map(\.id)
        })
        startupAttempt += 1
        startupPhase = .preparing
        await prepareStartup()
    }

    func continueStartup() {
        guard startupPhase == .needsAttention else { return }
        startupPhase = .finishing
        finishStartupIfReady()
    }

    private func finishStartupIfReady() {
        guard startupPhase == .finishing, startupSurfaceIDs.isEmpty, preparingLightSurfaces.isEmpty else { return }
        startupPhase = .ready
    }

    func cacheThumbnail(_ image: CGImage, for url: URL) {
        thumbnails[url] = image
        if imageAspects[url] == nil { imageAspects[url] = Double(image.width) / Double(image.height) }
        thumbnailOrder.removeAll { $0 == url }; thumbnailOrder.append(url)
        while thumbnailOrder.count > 300 { thumbnails.removeValue(forKey: thumbnailOrder.removeFirst()) }
    }

    func preparePreview(_ url: URL) async -> PhotoPreview? {
        if let cached = preparedPreviews[url] { return cached }
        if let task = previewTasks[url] { return await task.value }
        let task = Task { await PhotoStore.shared.preview(url) }
        previewTasks[url] = task
        let loaded = await task.value
        previewTasks[url] = nil
        guard let image = loaded else { return nil }
        preparedPreviews[url] = image
        imageAspects[url] = Double(image.aspect)
        previewOrder.removeAll { $0 == url }; previewOrder.append(url)
        let placed = Set(layout.slides.map(\.url) + albums.filter { $0.position != nil }.flatMap { $0.pockets.compactMap(\.url) })
        while previewOrder.count > 12,
              let index = previewOrder.firstIndex(where: { !placed.contains($0) }) {
            preparedPreviews.removeValue(forKey: previewOrder.remove(at: index))
        }
        return image
    }

    func tablePreviewMaxPixel(for url: URL, displayScale: CGFloat) -> Int {
        let slide = layout.slides.first { $0.url == url } ?? Slide(url: url, x: 0.5, y: 0.5)
        let aspect = imageAspects[url] ?? thumbnails[url].map { Double($0.width) / Double($0.height) } ?? 1.5
        let placement = screenPlacement(slide, aspect: aspect)
        return TablePreviewSizing.maxPixel(size: CGSize(width: placement.width, height: placement.height),
                                          displayScale: displayScale)
    }

    func prepareTablePreview(_ url: URL, maxPixel: Int) async -> PhotoPreview? {
        let key = TablePreviewRequest(url: url, maxPixel: maxPixel)
        if let cached = preparedTablePreviews[url], (tablePreviewSizes[url] ?? 0) >= key.maxPixel { return cached }
        let task: Task<PhotoPreview?, Never>
        let requestID: UUID
        if let pending = tablePreviewTasks[key] {
            task = pending.task
            requestID = pending.id
        } else {
            task = Task { await PhotoStore.shared.preview(url, maxPixel: key.maxPixel) }
            requestID = UUID()
            tablePreviewTasks[key] = (requestID, task)
        }
        let loaded = await task.value
        if tablePreviewTasks[key]?.id == requestID { tablePreviewTasks[key] = nil }
        guard let loaded else { return nil }
        // A late small request must not replace a completed larger request.
        if let cached = preparedTablePreviews[url], (tablePreviewSizes[url] ?? 0) > key.maxPixel { return cached }
        preparedTablePreviews[url] = loaded
        tablePreviewSizes[url] = key.maxPixel
        imageAspects[url] = Double(loaded.aspect)
        tablePreviewOrder.removeAll { $0 == url }; tablePreviewOrder.append(url)
        let placed = Set(layout.slides.map(\.url) + albums.filter { $0.position != nil }.flatMap { $0.pockets.compactMap(\.url) })
        while tablePreviewOrder.count > 12,
              let index = tablePreviewOrder.firstIndex(where: { !placed.contains($0) }) {
            let evicted = tablePreviewOrder.remove(at: index)
            preparedTablePreviews.removeValue(forKey: evicted)
            tablePreviewSizes.removeValue(forKey: evicted)
        }
        return loaded
    }

    @discardableResult
    func newTray() -> UUID {
        var number = trays.count + 1
        while trays.contains(where: { $0.name == "底栏 \(number)" }) { number += 1 }
        let tray = PhotoTray(name: "底栏 \(number)")
        trays.append(tray)
        selectedTrayID = tray.id
        cancelTrayPhotoSelection()
        save()
        return tray.id
    }

    func selectTray(_ id: UUID) {
        guard trays.contains(where: { $0.id == id }) else { return }
        setSelection([])
        guard id != activeTrayID else { return }
        selectedTrayID = id
        save()
    }

    func selectTrayPhoto(_ url: URL, in trayID: UUID) {
        let canonical = url.standardizedFileURL
        guard trayID == activeTrayID,
              trays[activeTrayIndex].urls.contains(where: { $0.standardizedFileURL == canonical }) else { return }
        let photo = TrayPhotoSelection(trayID: trayID, url: canonical)
        if isSelectingTrayPhotos {
            if !selectedTrayPhotos.insert(photo).inserted { selectedTrayPhotos.remove(photo) }
        } else {
            setSelection([])
            selectedTrayPhotos = [photo]
        }
    }

    func beginTrayPhotoSelection(_ url: URL, in trayID: UUID) {
        let canonical = url.standardizedFileURL
        guard trayID == activeTrayID,
              trays[activeTrayIndex].urls.contains(where: { $0.standardizedFileURL == canonical }) else { return }
        if !isSelectingTrayPhotos { setSelection([]) }
        isSelectingTrayPhotos = true
        selectedTrayPhotos.insert(TrayPhotoSelection(trayID: trayID, url: canonical))
    }

    func cancelTrayPhotoSelection() {
        selectedTrayPhotos.removeAll()
        isSelectingTrayPhotos = false
    }

    var canDeleteSelection: Bool { !selectedTrayPhotos.isEmpty || !selectedIDs.isEmpty }

    func deleteSelection() {
        if isSelectingTrayPhotos || !selectedTrayPhotos.isEmpty {
            let selected = selectedTrayPhotos.filter { $0.trayID == activeTrayID }
            deletePhotos(Set(selected.map(\.url)), fromTray: activeTrayID)
        } else { removeSelected() }
    }

    func deleteTray(_ id: UUID) {
        guard let index = trays.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTrayID == id
        let urls = Set(trays[index].urls)
        let removedIDs = Set(layout.slides.filter { urls.contains($0.url) }.map(\.id))
        for id in removedIDs { layout.remove(id) }
        tableOrder.removeAll { removedIDs.contains($0) }
        selectedIDs.subtract(removedIDs)
        trays.remove(at: index)
        // Keep an import destination, with a fresh identity so late imports
        // targeting the deleted last tray cannot repopulate it.
        if trays.isEmpty { trays = [PhotoTray(name: "底栏 1")] }
        if wasActive { selectedTrayID = trays[min(index, trays.count - 1)].id }
        cancelTrayPhotoSelection()
        if layout.slides.isEmpty { fitScale = 1 }
        trimReturnedPhotoPreviews()
        save()
    }

    func deletePhoto(_ url: URL, fromTray trayID: UUID) {
        deletePhotos([url], fromTray: trayID)
    }

    func deletePhotos(_ urls: Set<URL>, fromTray trayID: UUID) {
        guard let trayIndex = trays.firstIndex(where: { $0.id == trayID }) else { return }
        let canonical = Set(urls.map(\.standardizedFileURL))
            .intersection(trays[trayIndex].urls.map(\.standardizedFileURL))
        guard !canonical.isEmpty else { return }
        trays[trayIndex].urls.removeAll { canonical.contains($0.standardizedFileURL) }
        let removedIDs = Set(layout.slides.filter { canonical.contains($0.url.standardizedFileURL) }.map(\.id))
        for id in removedIDs { layout.remove(id) }
        tableOrder.removeAll { removedIDs.contains($0) }
        selectedIDs.subtract(removedIDs)
        cancelTrayPhotoSelection()
        if layout.slides.isEmpty { fitScale = 1 }
        trimReturnedPhotoPreviews()
        save()
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    func chooseFolder() {
        let trayID = activeTrayID
        let panel = NSOpenPanel()
        panel.title = "从文件夹导入"; panel.prompt = "导入照片"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { Task { await importURLs(panel.urls, into: trayID) } }
    }

    func choosePhotos() {
        let trayID = activeTrayID
        let panel = NSOpenPanel()
        panel.title = "添加照片"; panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { Task { await importURLs(panel.urls, into: trayID) } }
    }

    func importURLs(_ urls: [URL], into trayID: UUID? = nil) async {
        // Capture the destination before scanning, so switching tabs cannot redirect an import.
        let destination = trayID ?? activeTrayID
        importsInFlight += 1
        isImporting = true
        defer { importsInFlight -= 1; isImporting = importsInFlight > 0 }
        let found = await Task.detached(priority: .userInitiated) { PhotoLibrary.scan(urls) }.value
        guard !found.isEmpty else { message = "这里没有可读取的照片。支持 JPG、PNG、HEIC、TIFF 及系统支持的 RAW。"; return }
        guard let index = trays.firstIndex(where: { $0.id == destination }) else { return }
        if trays[index].urls.isEmpty, urls.count == 1, let source = urls.first,
           (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            trays[index].name = source.lastPathComponent
        }
        trays[index].urls = Self.uniqueURLs(trays[index].urls + found)
        save()
    }

    func place(_ url: URL, x: Double, y: Double) {
        guard PhotoLibrary.supported(url) else { return }
        if !allPhotos.contains(where: { $0.url == url.standardizedFileURL }) {
            photos.append(Photo(url: url.standardizedFileURL))
        }
        let id = layout.place(url, x: x, y: y)
        select(id)
        save()
    }

    func setSelection(_ ids: Set<UUID>) {
        cancelTrayPhotoSelection()
        let valid = ids.intersection(tableIDs)
        if valid != selectedIDs { selectedIDs = valid }
        selectionIndicatorsVisible = true
    }

    func select(_ id: UUID, extending: Bool = false, showIndicator: Bool = true) {
        guard tableIDs.contains(id) else { return }
        cancelTrayPhotoSelection()
        // Dragging still targets the item for Delete and raises it above other
        // films, but only an explicit click or marquee draws selection chrome.
        selectionIndicatorsVisible = showIndicator
        if extending, selectedIDs.contains(id) {
            selectedIDs.remove(id)
            return
        }
        if extending { selectedIDs.insert(id) } else { selectedIDs = [id] }
        synchronizeOrder()
        layout.bringToFront(id)
        tableOrder.removeAll { $0 == id }; tableOrder.append(id)
        save()
    }
    func update(_ id: UUID, change: (inout Slide) -> Void) { layout.update(id, change); save() }
    func removeSelected() {
        let ids = selectedIDs.intersection(tableIDs)
        guard !ids.isEmpty else { return }
        for id in ids { layout.remove(id) }
        for index in albums.indices where ids.contains(albums[index].id) { albums[index].position = nil }
        tableOrder.removeAll { ids.contains($0) }
        selectedIDs.removeAll()
        if layout.slides.isEmpty { fitScale = 1 }
        trimReturnedPhotoPreviews()
        save()
    }

    // Returning films should release excess model-held previews immediately,
    // without waiting for another photo load to apply the existing cache limit.
    private func trimReturnedPhotoPreviews() {
        let placed = Set(layout.slides.map(\.url) + onTableAlbums.flatMap { $0.pockets.compactMap(\.url) })
        while previewOrder.count > 12,
              let index = previewOrder.firstIndex(where: { !placed.contains($0) }) {
            preparedPreviews.removeValue(forKey: previewOrder.remove(at: index))
        }
        while tablePreviewOrder.count > 12,
              let index = tablePreviewOrder.firstIndex(where: { !placed.contains($0) }) {
            let evicted = tablePreviewOrder.remove(at: index)
            preparedTablePreviews.removeValue(forKey: evicted)
            tablePreviewSizes.removeValue(forKey: evicted)
        }
    }

    /// Rect is in board screen coordinates, after the camera transform.
    func select(in rect: CGRect) {
        let area = rect.standardized
        guard !area.isEmpty, !area.isInfinite, !area.isNull else { setSelection([]); return }
        var ids = Set<UUID>()
        for slide in layout.slides {
            let aspect = imageAspects[slide.url] ?? 1.5
            let placement = screenPlacement(slide, aspect: aspect)
            if Self.intersects(area, placement: placement) { ids.insert(slide.id) }
        }
        for page in onTableAlbums where albumFrame(page).intersects(area) { ids.insert(page.id) }
        setSelection(ids)
    }

    private static func intersects(_ rect: CGRect, placement p: SlidePlacement) -> Bool {
        let angle = p.angle * .pi / 180
        let c = cos(angle), s = sin(angle)
        let dx = rect.midX - p.x, dy = rect.midY - p.y
        let rw = rect.width / 2, rh = rect.height / 2
        let pw = p.width / 2, ph = p.height / 2
        // Separate on the marquee axes and on the rotated photograph axes.
        return abs(dx) <= rw + pw * abs(c) + ph * abs(s)
            && abs(dy) <= rh + pw * abs(s) + ph * abs(c)
            && abs(dx * c + dy * s) <= pw + rw * abs(c) + rh * abs(s)
            && abs(-dx * s + dy * c) <= ph + rw * abs(s) + rh * abs(c)
    }
    func clear() {
        layout.clear(); selectedID = nil; fitScale = 1; zoom = 1; pan = .zero
        for i in albums.indices { albums[i].position = nil }; tableOrder = []
        referenceSize = boardSize.width > 1 ? boardSize : nil
        trimReturnedPhotoPreviews()
        save()
    }

    func enterSlideshow() {
        let urls = Self.uniqueURLs(photos.map(\.url) + layout.slides.map(\.url))
        guard !slideshowMode, !urls.isEmpty else { return }
        slideshowOrder = urls.shuffled()
        slideshowIndex = 0
        slideshowMode = true
    }

    func exitSlideshow() {
        slideshowMode = false
        slideshowOrder = []
        slideshowIndex = 0
    }

    func nextSlide() {
        guard slideshowMode, !slideshowOrder.isEmpty else { return }
        slideshowIndex = (slideshowIndex + 1) % slideshowOrder.count
    }

    func previousSlide() {
        guard slideshowMode, !slideshowOrder.isEmpty else { return }
        slideshowIndex = (slideshowIndex - 1 + slideshowOrder.count) % slideshowOrder.count
    }

    var currentSlideURL: URL? {
        guard slideshowMode, slideshowOrder.indices.contains(slideshowIndex) else { return nil }
        return slideshowOrder[slideshowIndex]
    }

    var nextSlideURL: URL? {
        guard currentSlideURL != nil else { return nil }
        return slideshowOrder[(slideshowIndex + 1) % slideshowOrder.count]
    }


    func panBy(_ delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        pan.x += delta.width; pan.y += delta.height
        save()
    }

    func zoomCanvas(by factor: Double, around point: CGPoint? = nil) {
        guard factor.isFinite, factor > 0 else { return }
        let anchor = point ?? CGPoint(x: boardSize.width / 2, y: boardSize.height / 2)
        var camera = viewport
        camera.zoom(to: zoom * factor, aroundX: anchor.x, aroundY: anchor.y)
        zoom = camera.scale; pan = CGPoint(x: camera.offsetX, y: camera.offsetY)
        save()
    }

    func screenPlacement(_ slide: Slide, aspect: Double) -> SlidePlacement {
        viewport.screen(TableCoordinates.placement(slide, boardWidth: worldSize.width,
            boardHeight: worldSize.height, imageAspect: aspect, zoom: fitScale))
    }

    func normalizedWorldPoint(_ point: CGPoint) -> CGPoint {
        let world = viewport.world(x: point.x, y: point.y)
        return CGPoint(x: world.x / worldSize.width, y: world.y / worldSize.height)
    }

    func placeAtViewCenter(_ url: URL) {
        let point = normalizedWorldPoint(CGPoint(x: boardSize.width / 2, y: boardSize.height / 2))
        place(url, x: point.x, y: point.y)
    }

    func fitToWindow() {
        guard boardSize.width > 1, boardSize.height > 1 else { return }
        if albums.contains(where: { $0.position != nil }) { fitAlbumsAndSlides(); return }
        for slide in layout.slides where imageAspects[slide.url] == nil {
            imageAspects[slide.url] = PhotoLibrary.imageAspect(slide.url)
        }
        referenceSize = boardSize
        pan = .zero
        fitScale = layout.fitToWindow(boardWidth: boardSize.width, boardHeight: boardSize.height, imageAspects: imageAspects)
        zoom = 1
        save()
    }

    func placeAllPhotos() {
        guard boardSize.width > 1, boardSize.height > 1 else { return }
        let urls = photos.map(\.url)
        guard !urls.isEmpty else { return }

        // 先清空当前台面
        layout.clear()

        // 放置所有照片到中心
        for url in urls {
            let id = layout.place(url, x: 0.5, y: 0.5)
            layout.update(id) { $0.width = Slide.defaultWidth }
        }

        // 使用 fitToWindow 的逻辑来排列
        for slide in layout.slides where imageAspects[slide.url] == nil {
            imageAspects[slide.url] = PhotoLibrary.imageAspect(slide.url)
        }
        referenceSize = boardSize
        pan = .zero
        fitScale = layout.fitToWindow(boardWidth: boardSize.width, boardHeight: boardSize.height, imageAspects: imageAspects)
        zoom = 1
        selectedID = nil

        save()
    }

    var onTableAlbums: [AlbumPage] { albums.filter { $0.position != nil } }
    var tableIDs: [UUID] {
        let available = layout.slides.map(\.id) + onTableAlbums.map(\.id)
        let availableSet = Set(available)
        var seen = Set<UUID>()
        return (tableOrder + available).filter { availableSet.contains($0) && seen.insert($0).inserted }
    }
    func layerIndex(_ id: UUID) -> Double { Double(tableIDs.firstIndex(of: id) ?? 0) }
    private func synchronizeOrder() { tableOrder = tableIDs }
    @discardableResult func newAlbum() -> UUID {
        let page = AlbumPage(name: "相册第 \(albums.count + 1) 页")
        albums.append(page); editingAlbumID = page.id; save(); return page.id
    }
    func updateAlbum(_ id: UUID, _ change: (inout AlbumPage) -> Void) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        change(&albums[index]); save()
    }
    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }; tableOrder.removeAll { $0 == id }
        selectedIDs.remove(id)
        if editingAlbumID == id { editingAlbumID = albums.first?.id }
        save()
    }
    func placeAlbum(_ id: UUID, at point: CGPoint? = nil) {
        guard albums.contains(where: { $0.id == id }) else { return }
        let center = point ?? CGPoint(x: boardSize.width / 2, y: boardSize.height / 2)
        let world = viewport.world(x: center.x, y: center.y)
        updateAlbum(id) { $0.position = CGPoint(x: world.x, y: world.y) }
        select(id)
    }
    func albumFrame(_ page: AlbumPage) -> CGRect {
        let p = page.position ?? .zero
        let center = viewport.screen(x: p.x, y: p.y)
        return CGRect(x: center.x - AlbumPage.size.width * zoom / 2,
                      y: center.y - AlbumPage.size.height * zoom / 2,
                      width: AlbumPage.size.width * zoom, height: AlbumPage.size.height * zoom)
    }
    private func fitAlbumsAndSlides() {
        referenceSize = boardSize; fitScale = 1
        for slide in layout.slides {
            if imageAspects[slide.url] == nil { imageAspects[slide.url] = PhotoLibrary.imageAspect(slide.url) }
            layout.update(slide.id) { $0.width = Slide.defaultWidth }
        }
        let ids = tableIDs
        var maxW = AlbumPage.size.width, maxH = AlbumPage.size.height
        for slide in layout.slides {
            let p = TableCoordinates.placement(slide, boardWidth: worldSize.width, boardHeight: worldSize.height,
                                                imageAspect: imageAspects[slide.url] ?? 1.5)
            let c = abs(cos(p.angle * .pi / 180)), s = abs(sin(p.angle * .pi / 180))
            maxW = max(maxW, p.width * c + p.height * s)
            maxH = max(maxH, p.width * s + p.height * c)
        }
        let gap = 28.0
        var best = 0.0, columns = 1
        for cols in 1...max(1, ids.count) {
            let rows = (ids.count + cols - 1) / cols
            let scale = min(1, (boardSize.width - 48) / (Double(cols) * (maxW + gap) - gap),
                            (boardSize.height - 48) / (Double(rows) * (maxH + gap) - gap))
            if scale > best { best = scale; columns = cols }
        }
        let rows = (ids.count + columns - 1) / columns
        let totalW = Double(columns) * (maxW + gap) - gap
        let totalH = Double(rows) * (maxH + gap) - gap
        let size = worldSize
        for (index, id) in ids.enumerated() {
            let center = CGPoint(x: maxW / 2 + Double(index % columns) * (maxW + gap),
                                 y: maxH / 2 + Double(index / columns) * (maxH + gap))
            if let i = albums.firstIndex(where: { $0.id == id }) { albums[i].position = center }
            else { layout.update(id) { $0.x = center.x / size.width; $0.y = center.y / size.height } }
        }
        zoom = max(0.01, best)
        pan = CGPoint(x: (boardSize.width - totalW * zoom) / 2, y: (boardSize.height - totalH * zoom) / 2)
        save()
    }

    func accept(_ providers: [NSItemProvider], at point: CGPoint?, board: CGRect?) -> Bool {
        guard providers.contains(where: { provider in
            (PhotoDrag.acceptedTypes + [AlbumDrag.contentType]).contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }) else { return false }
        let trayID = activeTrayID
        Task { await acceptDrop(providers, at: point, board: board, into: trayID) }
        return true
    }

    /// Awaitable entry point also used by isolated drop regression checks.
    @discardableResult
    func acceptDrop(_ providers: [NSItemProvider], at point: CGPoint?, board: CGRect?, into trayID: UUID? = nil) async -> Bool {
        let destination = trayID ?? activeTrayID
        // Capture the drop camera before asynchronous decoding/import can change it.
        let dropCamera = viewport
        let dropWorldSize = referenceSize ?? board?.size ?? worldSize
        var internalURLs: [URL] = [], externalURLs: [URL] = []
        var albumIDs: [UUID] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(AlbumDrag.contentType.identifier) {
                if let id = await AlbumDrag.pageID(from: provider), albums.contains(where: { $0.id == id }) { albumIDs.append(id) }
            } else if provider.hasItemConformingToTypeIdentifier(PhotoDrag.contentType.identifier) {
                // An invalid/stale internal reference cannot fall back to file import.
                if let url = await PhotoDrag.sourceURL(from: provider),
                   allPhotos.contains(where: { $0.url == url }) { internalURLs.append(url) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      let url = await PhotoDrag.fileURL(from: provider) {
                externalURLs.append(url)
            }
        }
        guard !internalURLs.isEmpty || !externalURLs.isEmpty || !albumIDs.isEmpty else { return false }
        guard trays.contains(where: { $0.id == destination }) else { return false }
        // Folders always go to the tray, never automatically onto the lamp.
        if !externalURLs.isEmpty {
            await importURLs(externalURLs, into: destination)
            guard trays.contains(where: { $0.id == destination }) else { return false }
        }
        if let point, let board, board.width > 0, board.height > 0, board.contains(point) {
            for id in albumIDs {
                let world = dropCamera.world(x: point.x - board.minX, y: point.y - board.minY)
                updateAlbum(id) { $0.position = CGPoint(x: world.x, y: world.y) }; select(id)
            }
            var offset = 0.0
            for url in internalURLs + externalURLs where PhotoLibrary.supported(url) {
                // Internal drags only place a current library member: never append/import.
                guard allPhotos.contains(where: { $0.url == url }) else { continue }
                let world = dropCamera.world(x: point.x - board.minX + offset * board.width,
                                             y: point.y - board.minY + offset * board.height)
                selectedID = layout.place(url, x: world.x / dropWorldSize.width,
                                          y: world.y / dropWorldSize.height)
                if let selectedID { select(selectedID) }
                offset += 0.035
            }
            save()
        }
        return true
    }

    private struct Saved: Codable {
        var urls: [URL]; var layout: TableLayout; var label: String
        var fitScale: Double? = nil
        var worldWidth: Double? = nil
        var worldHeight: Double? = nil
        var viewport: TableViewport? = nil
        var albums: [AlbumPage]? = nil
        var tableOrder: [UUID]? = nil
        var trays: [PhotoTray]? = nil
        var activeTrayID: UUID? = nil
    }

    /// JSON remapping preserves immutable slide IDs and geometry without changing
    /// the core model API. Existing one-photo/one-slide semantics keep the topmost.
    private static func remapping(_ saved: Saved, aliases: [URL: URL]) throws -> Saved {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        object["urls"] = saved.urls.map { (aliases[$0.standardizedFileURL] ?? $0).absoluteString }
        if let trays = saved.trays {
            object["trays"] = trays.map { tray -> [String: Any] in
                ["id": tray.id.uuidString, "name": tray.name,
                 "urls": Self.uniqueURLs(tray.urls.map { aliases[$0.standardizedFileURL] ?? $0 }).map(\.absoluteString)]
            }
        }
        var layoutObject = object["layout"] as! [String: Any]
        let objects = layoutObject["slides"] as! [[String: Any]]
        var seen = Set<URL>()
        var mapped: [[String: Any]] = []
        for (slide, record) in zip(saved.layout.slides, objects).reversed() {
            let url = (aliases[slide.url.standardizedFileURL] ?? slide.url).standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            var value = record
            value["url"] = url.absoluteString
            mapped.append(value)
        }
        layoutObject["slides"] = Array(mapped.reversed())
        object["layout"] = layoutObject
        return try JSONDecoder().decode(Saved.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func save() {
        guard let storageURL else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            persist(to: storageURL)
        }
    }

    func flushSave() {
        saveTask?.cancel()
        guard let storageURL else { return }
        persist(to: storageURL)
    }

    private func persist(to storageURL: URL) {
        let saved = Saved(urls: allPhotos.map(\.url), layout: layout, label: sourceLabel, fitScale: fitScale,
                          worldWidth: referenceSize.map { Double($0.width) }, worldHeight: referenceSize.map { Double($0.height) }, viewport: viewport,
                          albums: albums, tableOrder: tableOrder, trays: trays, activeTrayID: activeTrayID)
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: storageURL, options: .atomic)
        } catch { message = "布局暂时无法保存：\(error.localizedDescription)" }
    }
}
