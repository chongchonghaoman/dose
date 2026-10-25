import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LightTableCore

private enum TableStyle {
    static let ink = Color(white: 0.16)
    static let secondary = Color(white: 0.40)
    static let chrome = Color(white: 0.97)
    static let unlitPanel = Color(red: 0.89, green: 0.85, blue: 0.75)
}

struct ContentView: View {
    @Bindable var model: TableModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flight: SleeveFlight?
    @State private var canvasFrame = CGRect.zero
    @State private var flightCursor = false
    @State private var cancelledPull = false
    @State private var flightPointer: CGPoint?
    @State private var loupe = LoupeExperience()
    @State private var slideshowTray = SlideshowTraySnapshot()
    @State private var entryPreparationID: UUID?
    @State private var entryPhotos: [SlideshowEntryPhoto] = []
    @State private var entryComplete = false

    init(model: TableModel, loupe: LoupeExperience? = nil) {
        self.model = model
        _loupe = State(initialValue: loupe ?? LoupeExperience())
    }

    var body: some View {
        ZStack {
            if !model.slideshowMode || !entryComplete {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        TableCanvas(model: model, loupe: loupe, liftedPhoto: flight?.photo.url)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: WorkbenchFrameKey.self, value: proxy.frame(in: .named("workbench")))
                            })
                        tools.padding(.top, 14).padding(.trailing, 24)
                    }
                    tray.padding(.horizontal, 16).padding(.vertical, 16)
                }
                .allowsHitTesting(!model.slideshowMode)
                .accessibilityHidden(model.slideshowMode)
            }
            if model.slideshowMode {
                SlideshowView(model: model, ready: entryComplete)
                    .opacity(entryComplete ? 1 : 0)
                if !entryComplete {
                    SlideshowEntry(photos: entryPhotos, reduceMotion: reduceMotion) {
                        entryComplete = true
                    }
                }
            }
        }
        .coordinateSpace(name: "workbench")
        .onPreferenceChange(WorkbenchFrameKey.self) { canvasFrame = $0 }
        .overlayPreferenceValue(SlideshowTrayAnchorsKey.self) { anchors in
            GeometryReader { proxy in
                Color.clear.preference(key: SlideshowTraySnapshotKey.self,
                                       value: anchors.resolved(in: proxy))
            }.allowsHitTesting(false)
        }
        .onPreferenceChange(SlideshowTraySnapshotKey.self) { slideshowTray = $0 }
        .onPreferenceChange(LoupeSceneKey.self) { scene in
            loupe.scene = scene
            if scene == nil { loupe.cancel() }
        }
        .overlay(alignment: .topLeading) {
            if let flight {
                SleeveFlightView(flight: flight, preview: model.preparedPreviews[flight.photo.url]?.viewing(transmitted: model.transmissionEnabled),
                                 isLit: model.isLit, brightness: model.lampBrightness, reduceMotion: reduceMotion)
                FilmSleeveSurface().frame(width: flight.sleeve.width, height: flight.sleeve.height)
                    .position(x: flight.sleeve.midX, y: flight.sleeve.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay {
            if !model.slideshowMode { LoupeOverlay(experience: loupe, canvasFrame: canvasFrame) }
        }
        .background {
            LoupeKeyboard(enabled: !model.slideshowMode && model.loupeEnabled && flight == nil && !model.albumEditorPresented,
                          pressed: { loupe.press() },
                          released: { loupe.release(reduceMotion: reduceMotion) },
                          cancelled: { loupe.cancel() }).frame(width: 0, height: 0)
        }
        .task(id: flight?.phase == .dragging) {
            guard flight?.phase == .dragging else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let point = flightPointer, boardFrame.contains(point) else { continue }
                let velocity = TableViewport.edgeVelocity(x: point.x - boardFrame.minX, y: point.y - boardFrame.minY,
                    width: boardFrame.width, height: boardFrame.height)
                if velocity.x != 0 || velocity.y != 0 {
                    model.panBy(CGSize(width: velocity.x * 0.016, height: velocity.y * 0.016))
                }
            }
        }
        .task(id: entryPreparationID) {
            guard let run = entryPreparationID else { return }
            await prepareSlideshow(run)
        }
        .onChange(of: model.loupeEnabled) { _, enabled in if !enabled { loupe.cancel() } }
        .onChange(of: model.slideshowMode) { _, active in
            loupe.cancel()
            flight = nil; flightPointer = nil; cancelledPull = false; releaseFlightCursor()
            if !active {
                entryPreparationID = nil
                entryComplete = false; entryPhotos = []
            }
        }
        .onExitCommand { loupe.cancel(); returnToSleeve() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in returnToSleeve() }
        .onDisappear {
            entryPreparationID = nil
            loupe.cancel(); flight = nil; cancelledPull = false; releaseFlightCursor()
        }
        .background(Color(white: 0.025))
        .sheet(isPresented: $model.albumEditorPresented) { AlbumEditor(model: model) }
        .onChange(of: model.albumEditorPresented) { _, opened in if opened { loupe.cancel() } }
        .alert("观片台", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var tools: some View {
        HStack(spacing: 9) {
            HStack(spacing: 2) {
                tool("arrow.up.and.down.and.arrow.left.and.right", "普通指针（A）", active: !model.loupeEnabled) { model.loupeEnabled = false }
                tool("viewfinder.circle", "放大镜（V）；按住空格凑近，松开退回", active: model.loupeEnabled) { model.loupeEnabled.toggle() }
            }.padding(4).background(TableStyle.chrome, in: Capsule())
            HStack(spacing: 2) {
                tool("minus", "缩小台面视野") { model.zoomCanvas(by: 1 / 1.2) }
                Button("整理全局", action: model.fitToWindow).buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 5)
                    .help("恢复默认尺寸、整理全部胶片并显示全局（⌘0）")
                tool("plus", "放大台面视野") { model.zoomCanvas(by: 1.2) }
            }.padding(4).background(TableStyle.chrome, in: Capsule())
            HStack(spacing: 7) {
                Image(systemName: "sun.max").font(.system(size: 12))
                BrightnessSlider(value: $model.lampBrightness, range: 0.1...1.6,
                                 defaultValue: TableModel.defaultLampBrightness)
                    .frame(width: 110, height: 22)
                Text("\(Int(model.lampBrightness * 100))%")
                    .font(.system(size: 10, design: .monospaced)).monospacedDigit().frame(width: 34)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(TableStyle.chrome, in: Capsule())
            .help("连续调整灯板和胶片的透光亮度；双击滑杆恢复 100%；关灯时可预设")
            Button {
                model.isLit.toggle()
            } label: {
                Label(model.isLit ? "关灯" : "开灯", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 17).frame(height: 38)
                    .foregroundStyle(model.isLit ? Color.black : Color.white)
                    .background(model.isLit ? Color.white : Color(white: 0.15), in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut("l", modifiers: .command)
            .help("模拟反转片背光；不修改原图")
            Button {
                startSlideshow()
            } label: {
                Label("幻灯片", systemImage: "play.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 17).frame(height: 38)
                    .foregroundStyle(.white)
                    .background(Color(white: 0.15), in: Capsule())
            }.buttonStyle(.plain)
            .help("进入幻灯片放映模式")
            .disabled(model.photos.isEmpty || entryPreparationID != nil)
        }.foregroundStyle(TableStyle.ink)
    }

    private func tool(_ symbol: String, _ help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 30, height: 30)
                .background(active ? Color.white : Color.clear, in: Circle())
                .overlay(Circle().stroke(Color.black.opacity(active ? 0.08 : 0), lineWidth: 1))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    private var tray: some View {
        let ink = Color(white: 0.92)
        let secondary = Color(white: 0.66)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: model.chooseFolder) {
                    Label("选择文件夹", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 32)
                        .foregroundStyle(.white).background(Color(white: 0.22), in: Capsule())
                }.buttonStyle(.plain)
                Button(action: model.choosePhotos) { Image(systemName: "plus").frame(width: 24, height: 28) }
                    .buttonStyle(.plain).help("添加照片")
                Button(action: model.placeAllPhotos) {
                    Label("一键平铺", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 32)
                        .foregroundStyle(.white).background(Color(white: 0.22), in: Capsule())
                }.buttonStyle(.plain)
                .help("将所有照片自动摆放到台面")
                .disabled(model.photos.isEmpty)
                Text(model.sourceLabel).font(.system(size: 11)).lineLimit(1)
                Text("\(model.photos.count) 张").font(.system(size: 10, design: .monospaced)).foregroundStyle(secondary)
                if model.isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button { model.albumEditorPresented = true } label: {
                    Label("相册", systemImage: "rectangle.stack").font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
            }
            if model.photos.isEmpty && model.albums.isEmpty {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text("选择一个照片文件夹，或把照片、文件夹拖到这里。")
                }.font(.system(size: 12)).foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(model.albums) { page in AlbumTrayCard(page: page, model: model) }
                        ForEach(model.photos) { photo in
                            TrayPhoto(photo: photo, model: model, lifted: flight?.photo.url == photo.url,
                                      onPull: pullFromSleeve, onRelease: releaseFromSleeve, onTrackingEnded: {
                                          returnToSleeve(); cancelledPull = false
                                      })
                                .opacity(model.slideshowMode ? 0 : 1)
                                .contextMenu {
                                    Button("放到灯板中央") { model.placeAtViewCenter(photo.url) }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
                                }
                        }
                    }.padding(.bottom, 3)
                }.frame(height: 88)
                .transformAnchorPreference(key: SlideshowTrayAnchorsKey.self, value: .bounds) { value, anchor in
                    value.viewport = anchor
                }
            }
        }
        .padding(14).foregroundStyle(ink)
        .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .onDrop(of: PhotoDrag.acceptedTypes, isTargeted: nil) { model.accept($0, at: nil, board: nil) }
    }

    private var boardFrame: CGRect {
        CGRect(x: canvasFrame.minX, y: canvasFrame.minY + 64,
               width: model.boardSize.width, height: model.boardSize.height)
    }

    private func startSlideshow() {
        guard !model.photos.isEmpty, !model.slideshowMode, entryPreparationID == nil else { return }
        if reduceMotion {
            entryComplete = true
            model.enterSlideshow()
        } else {
            entryPreparationID = UUID()
        }
    }

    @MainActor private func prepareSlideshow(_ run: UUID) async {
        defer { if entryPreparationID == run { entryPreparationID = nil } }
        do {
            // A click can arrive before LazyHStack has published its first anchors.
            for _ in 0..<8 {
                guard entryPreparationID == run, !Task.isCancelled else { return }
                if !visibleSlideshowPhotos.isEmpty { break }
                try await Task.sleep(for: .milliseconds(32))
            }
            // Decode only missing visible thumbnails; never prepare the full library.
            let missing = visibleSlideshowPhotos.filter { $0.image == nil && model.thumbnails[$0.url] == nil }
            for item in missing.prefix(12) {
                guard entryPreparationID == run, !Task.isCancelled, !model.slideshowMode else { return }
                if let image = await PhotoThumbnails.shared.thumbnail(item.url) {
                    model.cacheThumbnail(image, for: item.url)
                }
            }
            // Let newly available images appear in their sleeves before capturing them.
            try await Task.sleep(for: .milliseconds(32))
            guard entryPreparationID == run, !Task.isCancelled, !model.slideshowMode else { return }
            let photos = visibleSlideshowPhotos.compactMap { item -> SlideshowEntryPhoto? in
                guard let image = item.image ?? model.thumbnails[item.url] else { return nil }
                return SlideshowEntryPhoto(url: item.url, image: image, frame: item.frame)
            }
            guard !photos.isEmpty else {
                model.message = "底栏还没有可放映的照片。请滚动到照片，等待缩略图显示后重试。"
                return
            }
            entryPhotos = photos
            entryComplete = false
            model.enterSlideshow()
        } catch { return }
    }

    private var visibleSlideshowPhotos: [SlideshowTrayPhotoSnapshot] {
        let urls = Set(model.photos.map(\.url))
        guard slideshowTray.viewport.width > 1, slideshowTray.viewport.height > 1 else { return [] }
        return slideshowTray.photos.values.filter {
            let visible = $0.frame.intersection(slideshowTray.viewport)
            return urls.contains($0.url) && !visible.isNull && visible.width > 2 && visible.height > 2
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    private func targetSlide(for photo: Photo) -> Slide {
        model.layout.slides.first { $0.url == photo.url } ?? Slide(url: photo.url, x: 0.5, y: 0.5)
    }

    private func pullFromSleeve(_ photo: Photo, _ image: CGImage, _ sleeve: CGRect, _ value: DragGesture.Value) {
        guard !cancelledPull else { return }
        flightPointer = value.location
        if flight == nil {
            let origin = CGRect(x: sleeve.minX + 7, y: sleeve.minY + 9, width: 90, height: 56)
            flight = SleeveFlight(photo: photo, thumbnail: image, sleeve: sleeve, origin: origin,
                                  start: value.startLocation, frame: origin)
            Task { _ = await model.preparePreview(photo.url) }
            NSCursor.closedHand.push(); flightCursor = true
        }
        guard var current = flight, current.phase == .dragging, current.photo.url == photo.url else { return }
        let slide = targetSlide(for: photo)
        let placement = model.screenPlacement(slide, aspect: CGFloat(image.width) / CGFloat(image.height))
        current.expansion = SleeveMotion.expansion(origin: current.origin, pointer: value.location, start: current.start)
        current.frame = SleeveMotion.frame(origin: current.origin, pointer: value.location, start: current.start,
                                          target: CGSize(width: placement.width, height: placement.height))
        current.lift = reduceMotion ? 0 : SleeveMotion.smooth(hypot(value.translation.width, value.translation.height) / 28)
        current.angle = slide.angle * Double(current.expansion)
        if !reduceMotion { current.angle += Double(min(3, max(-3, value.translation.width / 40))) * (1 - Double(current.expansion)) }
        flight = current
        NSCursor.closedHand.set()
    }

    private func releaseFromSleeve(_ value: DragGesture.Value) {
        defer { cancelledPull = false }
        guard let current = flight, current.phase == .dragging else { return }
        guard boardFrame.contains(value.location) else { returnToSleeve(); return }
        var slide = targetSlide(for: current.photo)
        let point = model.normalizedWorldPoint(CGPoint(x: current.frame.midX - boardFrame.minX,
                                                     y: current.frame.midY - boardFrame.minY))
        slide.x = point.x; slide.y = point.y
        let p = model.screenPlacement(slide, aspect: CGFloat(current.thumbnail.width) / CGFloat(current.thumbnail.height))
        flight?.phase = .landing
        releaseFlightCursor()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22), completionCriteria: .removed) {
            flight?.frame = CGRect(x: boardFrame.minX + p.x - p.width / 2,
                                   y: boardFrame.minY + p.y - p.height / 2,
                                   width: p.width, height: p.height)
            flight?.expansion = 1; flight?.lift = 0; flight?.angle = slide.angle
        } completion: {
            guard flight?.id == current.id else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.place(current.photo.url, x: point.x, y: point.y)
                flight = nil
            }
        }
    }

    private func returnToSleeve() {
        guard let current = flight, current.phase == .dragging else { return }
        cancelledPull = true
        flight?.phase = .returning
        releaseFlightCursor()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.26), completionCriteria: .removed) {
            flight?.frame = current.origin; flight?.expansion = 0; flight?.lift = 0; flight?.angle = 0
        } completion: {
            if flight?.id == current.id { flight = nil }
        }
    }

    private func releaseFlightCursor() {
        if flightCursor { NSCursor.pop(); flightCursor = false }
    }
}

private struct TrayPhoto: View {
    let photo: Photo
    @Bindable var model: TableModel
    var lifted: Bool
    var onPull: (Photo, CGImage, CGRect, DragGesture.Value) -> Void
    var onRelease: (DragGesture.Value) -> Void
    var onTrackingEnded: () -> Void
    private var onTable: Bool { model.layout.slides.contains { $0.url == photo.url } }
    @State private var image: CGImage?
    @State private var loaded = false
    @State private var hovered = false
    @GestureState private var pulling = false
    var body: some View {
        VStack(spacing: 5) {
            FilmSleeve(image: image, failed: loaded && image == nil, onTable: onTable, highlighted: hovered, lifted: lifted)
                .anchorPreference(key: SlideshowTrayAnchorsKey.self, value: .bounds) {
                    SlideshowTrayAnchors(photos: [photo.url: SlideshowTrayPhotoAnchor(bounds: $0, image: image)])
                }
                .overlay {
                    GeometryReader { proxy in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("workbench"))
                                .updating($pulling) { _, active, _ in active = true }
                                .onChanged { value in
                                    if let image { onPull(photo, image, proxy.frame(in: .named("workbench")), value) }
                                }
                                .onEnded(onRelease))
                    }
                }
            Text(photo.name).font(.system(size: 9)).lineLimit(1).frame(width: 94).padding(.horizontal, 5)
        }.help(photo.url.lastPathComponent)
        .onChange(of: pulling) { _, active in if !active { onTrackingEnded() } }
        .onChange(of: model.thumbnails[photo.url] != nil) { _, available in
            if available, image == nil { image = model.thumbnails[photo.url] }
        }
        .accessibilityLabel(photo.name + (onTable ? "，已在灯板上" : "，可拖到灯板"))
        .task(id: photo.url) {
            image = model.thumbnails[photo.url] ?? PhotoThumbnailCache.cached(photo.url)
            if image == nil { image = await PhotoThumbnails.shared.thumbnail(photo.url) }
            if let image { model.cacheThumbnail(image, for: photo.url) }
            loaded = true
        }
        .onHover { hovered = $0 }
        .task(id: hovered) {
            guard hovered else { return }
            _ = await model.preparePreview(photo.url)
        }
    }
}

struct TableCanvas: View {
    @Bindable var model: TableModel
    var loupe: LoupeExperience
    var liftedPhoto: URL? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targeted = false
    @State private var lightAnimating = false
    @State private var livePlacements: [UUID: SlidePlacement] = [:]
    @State private var draggingID: UUID?
    @State private var lensPreviews: [URL: PhotoPreview] = [:]
    @State private var panStart: CGPoint?
    @State private var canvasMagnification: CGFloat = 1
    @State private var canvasZoomAnchor: CGPoint?
    @State private var hasPanCursor = false
    @GestureState private var isPanning = false
    @GestureState private var isCanvasZooming = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !lightAnimating)) { _ in
            let elapsed = model.lightStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            let light = LightResponse.sample(elapsed: elapsed, isLit: model.isLit && model.lightStartedAt != nil, reduceMotion: reduceMotion)
        GeometryReader { proxy in
            let fitted = TableCoordinates.fit(width: proxy.size.width, height: proxy.size.height - 64)
            let size = CGSize(width: fitted.width, height: fitted.height)
            let rect = CGRect(x: 0, y: 64, width: size.width, height: size.height)
            let canvasRect = CGRect(origin: .zero, size: proxy.size)
            let lensPoint = model.loupeEnabled && draggingID == nil && liftedPhoto == nil && !isPanning ? loupe.sourcePoint.flatMap { canvasRect.contains($0) ? $0 : nil } : nil
            let viewport = lensPoint.map {
                LoupeRenderer.sourceViewport(point: $0, diameter: OpticalLoupe.diameter, magnification: OpticalLoupe.magnification)
            }
            let lensItems = sceneItems(viewport: viewport, offset: rect.origin)
            ZStack(alignment: .topLeading) {
                LampPanel(isLit: model.isLit, targeted: targeted, transmission: light.transmission, flare: light.flare, glow: light.glow, brightness: model.lampBrightness)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .contentShape(Rectangle()).onTapGesture { model.selectedID = nil }
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("table"))
                        .updating($isPanning) { _, active, _ in active = true }
                        .onChanged { value in
                            guard !loupe.isClose && !isCanvasZooming else { return }
                            if panStart == nil { panStart = model.pan; loupe.cancel() }
                            if !hasPanCursor { NSCursor.closedHand.push(); hasPanCursor = true }
                            model.pan = CGPoint(x: panStart!.x + value.translation.width,
                                                y: panStart!.y + value.translation.height)
                            NSCursor.closedHand.set()
                        }
                        .onEnded { _ in endPan() })
                    .simultaneousGesture(MagnificationGesture()
                        .updating($isCanvasZooming) { _, active, _ in active = true }
                        .onChanged { value in
                            guard value.isFinite, value > 0 else { return }
                            if canvasZoomAnchor == nil {
                                let point = loupe.pointer ?? CGPoint(x: rect.midX, y: rect.midY)
                                canvasZoomAnchor = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
                            }
                            model.zoomCanvas(by: value / canvasMagnification, around: canvasZoomAnchor)
                            canvasMagnification = value
                        }
                        .onEnded { _ in endCanvasZoom() })
                if model.layout.slides.isEmpty && model.onTableAlbums.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 26, weight: .ultraLight))
                        Text("把喜欢的照片，放到光里").font(.system(size: 13))
                        Text("从下方拖入 · 拖动空白处移台 · ⌘0 整理全局").font(.system(size: 10))
                    }
                    .foregroundStyle(Color.black.opacity(0.40))
                    .position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                }
                ForEach(model.layout.slides) { slide in
                    SlideView(model: model, slide: slide, boardSize: size, transmission: light.transmission, flare: light.flare, draggingID: $draggingID)
                        .opacity(slide.url == liftedPhoto ? 0 : 1)
                        .offset(x: rect.minX, y: rect.minY)
                        .zIndex(model.layerIndex(slide.id) + 1)
                }
                ForEach(model.onTableAlbums) { page in
                    AlbumTableView(page: page, model: model, transmission: light.transmission, flare: light.flare, draggingID: $draggingID)
                        .offset(x: rect.minX, y: rect.minY)
                        .zIndex(model.layerIndex(page.id) + 1)
                }
            }
            .preference(key: LoupeSceneKey.self, value: lensPoint.map {
                LoupeSceneInput(photos: lensItems.map(\.photo), point: $0, panelBounds: nil,
                    transmission: light.transmission, flare: light.flare, brightness: model.lampBrightness)
            })
            .onPreferenceChange(SlidePresentationKey.self) { livePlacements = $0 }
            .onChange(of: draggingID) { _, id in if id != nil { loupe.cancel() } }
            .onChange(of: isPanning) { _, active in if !active { endPan() } }
            .onChange(of: isCanvasZooming) { _, active in if !active { endCanvasZoom() } }
            .onDisappear { endPan(); endCanvasZoom() }
            .background {
                CanvasNavigation(enabled: !model.slideshowMode && draggingID == nil && liftedPhoto == nil && !isPanning && !isCanvasZooming,
                    moved: { model.panBy($0) }, zoomed: { model.zoomCanvas(by: $0, around: $1) })
            }
            .coordinateSpace(name: "table")
            .onContinuousHover { phase in
                switch phase { case .active(let point): loupe.pointer = point; case .ended: loupe.pointer = nil }
            }
            .onDrop(of: PhotoDrag.acceptedTypes + [AlbumDrag.contentType], isTargeted: $targeted) { providers, point in
                model.accept(providers, at: point, board: rect)
            }
            .clipped()
            .onChange(of: size, initial: true) { _, value in model.boardSize = value }
            .task(id: lensItems.compactMap(\.url)) {
                // Keep just the active viewport's previews when the shared
                // cache evicts them. A gap may need more than one photograph.
                let urls = Set(lensItems.compactMap(\.url))
                lensPreviews = lensPreviews.filter { urls.contains($0.key) }
                for url in urls where lensPreviews[url] == nil {
                    let loaded = await model.preparePreview(url)
                    guard !Task.isCancelled else { return }
                    if let loaded { lensPreviews[url] = loaded }
                }
            }
        }
        }
        .task(id: model.lightStartedAt) {
            guard model.isLit && model.lightStartedAt != nil && !reduceMotion else { lightAnimating = false; return }
            lightAnimating = true
            try? await Task.sleep(for: .seconds(LightResponse.settlingDuration + 0.1))
            guard !Task.isCancelled else { return }
            lightAnimating = false
        }
    }

    private func sceneItems(viewport: CGRect?, offset: CGPoint) -> [(url: URL?, photo: LoupeScenePhoto)] {
        guard let viewport else { return [] }
        var result: [(url: URL?, photo: LoupeScenePhoto)] = []
        func append(_ photo: LoupeScenePhoto, url: URL? = nil) {
            if photo.bounds.intersects(viewport) { result.append((url, photo)) }
        }
        for id in model.tableIDs {
            if let slide = model.layout.slides.first(where: { $0.id == id }) {
                let preview = (model.preparedPreviews[slide.url] ?? lensPreviews[slide.url])?.viewing(transmitted: model.transmissionEnabled)
                let aspect = preview.map { Double($0.aspect) } ?? model.imageAspects[slide.url] ?? 1.5
                let p = livePlacements[slide.id] ?? model.screenPlacement(slide, aspect: aspect)
                append(LoupeScenePhoto(preview: preview, thumbnail: model.thumbnails[slide.url],
                    center: CGPoint(x: p.x + offset.x, y: p.y + offset.y),
                    imageSize: CGSize(width: p.width, height: p.height), angle: p.angle, mountScale: model.zoom), url: slide.url)
            } else if let page = model.albums.first(where: { $0.id == id && $0.position != nil }) {
                let frame = model.albumFrame(page).offsetBy(dx: offset.x, dy: offset.y)
                guard frame.intersects(viewport) else { continue }
                func surface(_ front: Bool) {
                    if let image = AlbumSurface.image(page, front: front) {
                        append(LoupeScenePhoto(preview: nil, center: CGPoint(x: frame.midX, y: frame.midY),
                            imageSize: frame.size, mountScale: 0, surface: image))
                    }
                }
                surface(false)
                for pocket in page.pockets {
                    guard let url = pocket.url else { continue }
                    let preview = (model.preparedPreviews[url] ?? lensPreviews[url])?.viewing(transmitted: model.transmissionEnabled)
                    let aspect = preview.map { Double($0.aspect) } ?? model.imageAspects[url] ?? 1.5
                    let rect = AlbumPage.imageRect(pocket, aspect: aspect)
                    append(LoupeScenePhoto(preview: preview, thumbnail: model.thumbnails[url],
                        center: CGPoint(x: frame.minX + rect.midX * model.zoom, y: frame.minY + rect.midY * model.zoom),
                        imageSize: CGSize(width: rect.width * model.zoom, height: rect.height * model.zoom),
                        mountScale: model.zoom), url: url)
                }
                surface(true)
            }
        }
        return result
    }

    private func endPan() {
        panStart = nil
        if hasPanCursor { NSCursor.pop(); hasPanCursor = false }
        model.save()
    }

    private func endCanvasZoom() {
        canvasMagnification = 1
        canvasZoomAnchor = nil
    }
}

struct LampPanel: View {
    let isLit: Bool
    let targeted: Bool
    let transmission: Double
    let flare: Double
    let glow: Double
    let brightness: Double
    var body: some View {
        Rectangle()
            .fill(TableStyle.unlitPanel)
            .overlay { Color(white: LightResponse.panelWhite(brightness: brightness, flare: flare)).opacity(transmission) }
            .overlay {
                Rectangle().stroke(.white.opacity(glow * min(1, brightness) * 0.65), lineWidth: 16).blur(radius: 12)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(Color.black.opacity(isLit ? 0.03 : 0.06)).frame(height: 1)
            }
            .overlay {
                Canvas { context, size in
                    let inset: CGFloat = 12
                    let step: CGFloat = 6
                    var ticks = Path()
                    for index in 0...max(0, Int((size.width - inset * 2) / step)) {
                        let x = inset + CGFloat(index) * step
                        let length: CGFloat = index.isMultiple(of: 10) ? 7 : (index.isMultiple(of: 5) ? 4.5 : 2.5)
                        ticks.move(to: CGPoint(x: x, y: inset)); ticks.addLine(to: CGPoint(x: x, y: inset + length))
                    }
                    for index in 0...max(0, Int((size.height - inset * 2) / step)) {
                        let y = inset + CGFloat(index) * step
                        let length: CGFloat = index.isMultiple(of: 10) ? 7 : (index.isMultiple(of: 5) ? 4.5 : 2.5)
                        ticks.move(to: CGPoint(x: inset, y: y)); ticks.addLine(to: CGPoint(x: inset + length, y: y))
                    }
                    context.stroke(ticks, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
                }.allowsHitTesting(false)
            }
            .overlay(Rectangle().stroke(targeted ? Color.white.opacity(0.8) : .clear, lineWidth: 2))
            .accessibilityLabel(isLit ? "观片台已点亮" : "观片台已关闭")
    }
}

private struct SlideView: View {
    @Bindable var model: TableModel
    let slide: Slide
    let boardSize: CGSize
    let transmission: Double
    let flare: Double
    @State private var preview: PhotoPreview?
    @State private var failed = false
    @State private var resizeStart: Double?
    @State private var dragStartPan: CGPoint?
    @State private var dragPointer: CGPoint?
    @Binding private var draggingID: UUID?
    @State private var hasDragCursor = false
    @GestureState private var isDragging = false
    @GestureState private var movement = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var rotation = Angle.zero

    init(model: TableModel, slide: Slide, boardSize: CGSize, transmission: Double, flare: Double, draggingID: Binding<UUID?>) {
        self.model = model; self.slide = slide; self.boardSize = boardSize
        self.transmission = transmission; self.flare = flare
        _draggingID = draggingID
        _preview = State(initialValue: model.preparedPreviews[slide.url])
    }

    private var selected: Bool { model.selectedID == slide.id }
    private var resting: SlidePlacement {
        TableCoordinates.placement(slide, boardWidth: model.worldSize.width, boardHeight: model.worldSize.height,
                                   imageAspect: aspect, zoom: model.displayZoom)
    }
    private var displayed: SlidePlacement {
        let startPan = dragStartPan ?? model.pan
        let worldMovement = CGSize(width: (movement.width + startPan.x - model.pan.x) / model.zoom,
                                   height: (movement.height + startPan.y - model.pan.y) / model.zoom)
        return model.viewport.screen(SlidePresentation.placement(slide, board: model.worldSize, aspect: aspect,
            zoom: model.displayZoom, movement: worldMovement, magnification: magnification, rotation: rotation.degrees))
    }
    private var width: CGFloat { displayed.width }
    private var aspect: CGFloat {
        if let preview { return preview.aspect }
        if let thumbnail = model.thumbnails[slide.url] { return CGFloat(thumbnail.width) / CGFloat(thumbnail.height) }
        return model.imageAspects[slide.url] ?? 1.5
    }

    var body: some View {
        let imageSize = CGSize(width: width, height: width / aspect)
        ZStack {
            Color(white: 0.025)
            if let preview {
                image(preview, size: imageSize)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(model.isLit ? 0.012 : 0.065), .clear, .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .frame(width: imageSize.width, height: imageSize.height)
            } else if !failed, let thumbnail = model.thumbnails[slide.url] {
                Image(decorative: thumbnail, scale: 1).resizable().interpolation(.high)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .colorMultiply(Color(white: 0.10 + 0.90 * transmission))
            } else {
                VStack(spacing: 7) {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                    Text(failed ? "无法读取照片" : "读取中").font(.system(size: 9))
                }.foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(width: width, height: width / aspect)
        .overlay(Rectangle().stroke(selected ? Color.white.opacity(0.75) : Color.clear, lineWidth: selected ? 1 : 0.5))
        .overlay(alignment: .bottomTrailing) {
            if selected && !model.loupeEnabled {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10)).padding(4).background(.white, in: Circle()).foregroundStyle(.black)
                    .offset(x: 7, y: 7)
                    .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("table")).onChanged { value in
                        if resizeStart == nil { resizeStart = slide.width }
                        let local = TableCoordinates.localPoint(x: value.translation.width, y: value.translation.height,
                                                                centerX: 0, centerY: 0, angle: slide.angle)
                        let delta = local.x / (min(model.worldSize.width, model.worldSize.height) * model.displayZoom * model.zoom)
                        model.update(slide.id) { $0.width = (resizeStart ?? slide.width) + delta }
                    }.onEnded { _ in resizeStart = nil })
            }
        }
        .shadow(color: .black.opacity(model.isLit ? 0.22 : 0.36), radius: 2, x: 1, y: 2)
        .rotationEffect(.degrees(displayed.angle))
        .onTapGesture { model.select(slide.id) }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("table"))
            .updating($isDragging) { _, state, _ in state = true }
            .updating($movement) { value, state, _ in state = value.translation }
            .onChanged { value in
                if dragStartPan == nil { dragStartPan = model.pan }
                dragPointer = value.location
                draggingID = slide.id
                if !selected { model.select(slide.id) }
                setDragCursor(active: true)
                NSCursor.closedHand.set()
            }
            .onEnded { value in
                commit {
                    let start = dragStartPan ?? model.pan
                    $0.x = (resting.x + (value.translation.width + start.x - model.pan.x) / model.zoom) / model.worldSize.width
                    $0.y = (resting.y + (value.translation.height + start.y - model.pan.y) / model.zoom) / model.worldSize.height
                }
                dragStartPan = nil; dragPointer = nil
            })
        .task(id: isDragging) {
            guard isDragging else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let pointer = dragPointer else { continue }
                let velocity = TableViewport.edgeVelocity(x: pointer.x, y: pointer.y - 64,
                    width: boardSize.width, height: boardSize.height)
                if velocity.x != 0 || velocity.y != 0 {
                    model.panBy(CGSize(width: velocity.x * 0.016, height: velocity.y * 0.016))
                }
            }
        }
        .onChange(of: isDragging) { _, active in
            setDragCursor(active: active)
            if !active && draggingID == slide.id { draggingID = nil; dragStartPan = nil; dragPointer = nil }
        }
        .onDisappear {
            model.finishLightPreparation(slide.id)
            setDragCursor(active: false)
            if draggingID == slide.id { draggingID = nil }
        }
        .simultaneousGesture(MagnificationGesture().updating($magnification) { value, state, _ in state = value }
            .onEnded { value in commit { $0.width *= value } })
        .simultaneousGesture(RotationGesture().updating($rotation) { value, state, _ in state = value }
            .onEnded { value in commit { $0.angle += value.degrees } })
        .contextMenu {
            Button("移出台面") { model.select(slide.id); model.removeSelected() }
            Button("摆正") { model.update(slide.id) { $0.angle = 0 } }
            Divider()
            Button("逆时针旋转 15°") { model.update(slide.id) { $0.angle -= 15 } }
            Button("顺时针旋转 15°") { model.update(slide.id) { $0.angle += 15 } }
            Button("缩小胶片") { model.update(slide.id) { $0.width /= 1.12 } }
            Button("放大胶片") { model.update(slide.id) { $0.width *= 1.12 } }
        }
        .accessibilityLabel(slide.url.lastPathComponent)
        .onAppear { if preview == nil { model.beginLightPreparation(slide.id) } }
        .task(id: slide.url) {
            if preview == nil { model.beginLightPreparation(slide.id) }
            if model.thumbnails[slide.url] == nil,
               let thumbnail = await PhotoThumbnails.shared.thumbnail(slide.url) {
                model.cacheThumbnail(thumbnail, for: slide.url)
            }
            let loaded = await model.preparePreview(slide.url)
            guard !Task.isCancelled else { model.finishLightPreparation(slide.id); return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                preview = loaded; failed = loaded == nil
                model.finishLightPreparation(slide.id)
            }
        }
        .preference(key: SlidePresentationKey.self,
                    value: magnification != 1 || rotation != .zero ? [slide.id: displayed] : [:])
        .position(x: displayed.x, y: displayed.y)
        .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
    }

    private func setDragCursor(active: Bool) {
        guard active != hasDragCursor else { return }
        hasDragCursor = active
        if active { NSCursor.closedHand.push() } else { NSCursor.pop() }
    }

    private func commit(_ change: (inout Slide) -> Void) {
        var value = slide
        change(&value)
        let placement = TableCoordinates.placement(value, boardWidth: model.worldSize.width, boardHeight: model.worldSize.height,
                                                   imageAspect: aspect, zoom: model.displayZoom)
        model.update(slide.id) {
            $0.x = placement.x / model.worldSize.width
            $0.y = placement.y / model.worldSize.height
            $0.width = placement.width / (min(model.worldSize.width, model.worldSize.height) * model.displayZoom)
            $0.angle = value.angle
        }
    }

    private func image(_ preview: PhotoPreview, size: CGSize) -> some View {
        TransmittedPhoto(preview: preview.viewing(transmitted: model.transmissionEnabled), size: size, transmission: transmission, flare: flare, brightness: model.lampBrightness)
    }
}

/// The same layers are used inside and outside the lens, with no per-photo clock.
struct TransmittedPhoto: View {
    let preview: PhotoPreview
    let size: CGSize
    let transmission: Double
    let flare: Double
    var brightness: Double = 1
    // Offscreen exports/tests use the CPU-readable path; live windows use Metal.
    var usesMetal = true

    var body: some View {
        Group {
            if usesMetal && OpticalMetalView.gpu != nil {
                OpticalDisplay(preview: preview, transmission: transmission, flare: flare,
                    brightness: brightness)
            } else { sdrBody }
        }.frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var sdrBody: some View {
        if flare > 0 || brightness > 1, let image = PhotoOptics.sdrImage(preview: preview, transmission: transmission,
                                                     flare: flare, brightness: brightness) {
            layer(image)
        } else { steadySDRBody }
    }

    private var steadySDRBody: some View {
        ZStack {
            layer(transmission > 0 ? preview.dark : preview.source)
            if transmission > 0 {
                ZStack {
                    layer(preview.lit)
                    layer(preview.boosted).opacity(LightResponse.photoBrightnessMix(brightness: brightness))
                    layer(preview.flare).blendMode(.screen)
                        .opacity(LightResponse.photoGlowMix(flare: flare, brightness: brightness))
                }
                .compositingGroup()
                .colorMultiply(Color(white: LightResponse.photoLevel(brightness: brightness)))
                .opacity(transmission)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func layer(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.high)
            .frame(width: size.width, height: size.height)
    }
}

struct OpticalLoupe: View {
    static let diameter: CGFloat = LoupeGeometry.diameter
    static let magnification: CGFloat = LoupeGeometry.magnification
    let image: CGImage?
    var live: LoupeDisplayInput? = nil
    let transmission: Double
    var flare: Double = 0
    var brightness: Double = 1
    var contentScale: CGFloat = 1
    var glass = LoupeGlassPose()
    var viewportSize = CGSize(width: LoupeGeometry.diameter, height: LoupeGeometry.diameter)
    var apertureDiameter: CGFloat = LoupeGeometry.diameter
    var opticalCenter: CGPoint? = nil

    var body: some View {
        let center = opticalCenter ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        ZStack {
            TableStyle.unlitPanel
            Color(white: LightResponse.panelWhite(brightness: brightness, flare: flare)).opacity(transmission)
            if let live {
                OpticalDisplay(loupe: live, transmission: transmission)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .scaleEffect(contentScale)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                .frame(width: viewportSize.width, height: viewportSize.height)
                .scaleEffect(contentScale)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .mask {
            Circle().frame(width: apertureDiameter, height: apertureDiameter).position(center)
        }
        .overlay {
            Circle().fill(RadialGradient(stops: [
                .init(color: .clear, location: 0.94),
                .init(color: .black.opacity(0.008), location: 0.98),
                .init(color: .black.opacity(0.035), location: 1)
            ], center: .center, startRadius: 0, endRadius: apertureDiameter / 2))
                .frame(width: apertureDiameter, height: apertureDiameter).position(center)
                .opacity(glass.intensity)
        }
        .overlay {
            LoupeGlassSurface(pose: glass, transmission: transmission)
                .frame(width: apertureDiameter, height: apertureDiameter).position(center)
        }
        .clipped()
        .accessibilityLabel("观片放大镜")
    }
}

private struct SlideshowTrayPhotoAnchor {
    let bounds: Anchor<CGRect>
    let image: CGImage?
}

private struct SlideshowTrayAnchors {
    var photos: [URL: SlideshowTrayPhotoAnchor] = [:]
    var viewport: Anchor<CGRect>?

    func resolved(in proxy: GeometryProxy) -> SlideshowTraySnapshot {
        SlideshowTraySnapshot(photos: photos.reduce(into: [:]) { result, pair in
            let (url, item) = pair
            let sleeve = proxy[item.bounds]
            result[url] = SlideshowTrayPhotoSnapshot(url: url, image: item.image,
                frame: CGRect(x: sleeve.minX + 7, y: sleeve.minY + 9, width: 90, height: 56))
        }, viewport: viewport.map { proxy[$0] } ?? .zero)
    }
}

private struct SlideshowTrayAnchorsKey: PreferenceKey {
    static let defaultValue = SlideshowTrayAnchors()
    static func reduce(value: inout SlideshowTrayAnchors, nextValue: () -> SlideshowTrayAnchors) {
        let next = nextValue()
        value.photos.merge(next.photos, uniquingKeysWith: { _, latest in latest })
        if let viewport = next.viewport { value.viewport = viewport }
    }
}

private struct SlideshowTrayPhotoSnapshot: Equatable {
    let url: URL
    let image: CGImage?
    let frame: CGRect

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.frame == rhs.frame && lhs.image === rhs.image
    }
}

private struct SlideshowTraySnapshot: Equatable {
    var photos: [URL: SlideshowTrayPhotoSnapshot] = [:]
    var viewport = CGRect.zero
}

private struct SlideshowTraySnapshotKey: PreferenceKey {
    static let defaultValue = SlideshowTraySnapshot()
    static func reduce(value: inout SlideshowTraySnapshot, nextValue: () -> SlideshowTraySnapshot) { value = nextValue() }
}
