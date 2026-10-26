import SwiftUI
import AppKit
import LightTableCore

struct AlbumArtwork: View {
    let page: AlbumPage
    var model: TableModel
    var transmission: Double = 0
    var flare: Double = 0
    var backlit = false
    var catalog = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            membrane(front: false)
            ForEach(page.pockets) { pocket in
                if let url = pocket.url {
                    let aspect = model.imageAspects[url] ?? 1.5
                    let rect = AlbumPage.imageRect(pocket, aspect: aspect)
                    AlbumFilm(url: url, lightSurfaceID: pocket.id, model: model, transmission: transmission, flare: flare,
                              backlit: backlit, catalog: catalog)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            membrane(front: true)
        }.frame(width: AlbumPage.size.width, height: AlbumPage.size.height)
    }
    @ViewBuilder private func membrane(front: Bool) -> some View {
        if let image = AlbumSurface.image(page, front: front) {
            Image(decorative: image, scale: 2).resizable()
                .frame(width: AlbumPage.size.width, height: AlbumPage.size.height).allowsHitTesting(false)
        }
    }
}

private struct AlbumFilm: View {
    let url: URL
    let lightSurfaceID: UUID
    @Environment(\.displayScale) private var displayScale
    let model: TableModel
    let transmission: Double
    let flare: Double
    let backlit: Bool
    let catalog: Bool
    @State private var preview: PhotoPreview?
    @State private var thumbnail: CGImage?
    @State private var failed = false
    @State private var previewURL: URL?
    var body: some View {
        GeometryReader { proxy in
            let zoom = backlit && !catalog ? model.zoom : 1
            let size = CGSize(width: proxy.size.width * zoom, height: proxy.size.height * zoom)
            let request = TablePreviewRequest(url: url,
                maxPixel: TablePreviewSizing.maxPixel(size: size, displayScale: displayScale))
            Group {
                if let preview, !catalog {
                    TransmittedPhoto(preview: preview.viewing(transmitted: model.transmissionEnabled), size: proxy.size, transmission: transmission,
                                     flare: flare, brightness: model.lampBrightness)
                } else if let image = thumbnail ?? model.thumbnails[url] {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .colorMultiply(Color(white: catalog ? 1 : 0.10 + 0.90 * transmission))
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Color(white: 0.035) }
            }.frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: TableModel.SurfaceRequest(preview: request, attempt: model.startupAttempt)) {
                if previewURL != url {
                    preview = nil; thumbnail = model.thumbnails[url]; failed = false; previewURL = url
                }
                if backlit && !catalog && preview == nil { model.beginLightPreparation(lightSurfaceID) }
                defer {
                    if backlit && !catalog && !Task.isCancelled { model.finishLightPreparation(lightSurfaceID) }
                }
                if preview != nil {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                }
                thumbnail = thumbnail ?? PhotoThumbnailCache.cached(url)
                if thumbnail == nil { thumbnail = await PhotoThumbnails.shared.thumbnail(url) }
                guard !Task.isCancelled else { return }
                if let thumbnail { model.cacheThumbnail(thumbnail, for: url) }
                if backlit && !catalog {
                    let loaded = await model.prepareTablePreview(request.url, maxPixel: request.maxPixel)
                    guard !Task.isCancelled else { return }
                    if let loaded { preview = loaded }
                }
                failed = thumbnail == nil && preview == nil
            }
        }
        .onAppear {
            if backlit && !catalog && preview == nil { model.beginLightPreparation(lightSurfaceID) }
        }
        .onDisappear { if backlit && !catalog { model.finishLightPreparation(lightSurfaceID) } }
        .accessibilityLabel(url.lastPathComponent)
    }
}

struct AlbumTrayCard: View {
    let page: AlbumPage
    var model: TableModel
    var body: some View {
        VStack(spacing: 5) {
            AlbumArtwork(page: page, model: model, catalog: true)
                .scaleEffect(0.095).frame(width: 69, height: 66)
                .background(Color(white: 0.20))
                .contentShape(Rectangle())
                .onDrag { AlbumDrag.provider(page.id) } preview: {
                    AlbumArtwork(page: page, model: model, catalog: true)
                        .scaleEffect(0.28).frame(width: 174, height: 194)
                }
                .onTapGesture(count: 2) { model.editingAlbumID = page.id; model.albumEditorPresented = true }
            Text(page.name).font(.system(size: 9)).lineLimit(1).frame(width: 90)
        }
        .padding(.horizontal, 7)
        .help("\(page.photoCount) 张 · 整页拖到台面 · 双击编辑")
        .contextMenu {
            Button("编辑相册页") { model.editingAlbumID = page.id; model.albumEditorPresented = true }
            Button("整页放上观片台") { model.placeAlbum(page.id) }
        }
    }
}

struct AlbumTableView: View {
    let page: AlbumPage
    var model: TableModel
    let transmission: Double
    let flare: Double
    @Binding var draggingID: UUID?
    @State private var dragOrigin: CGPoint?
    @State private var startPan: CGPoint?
    @State private var pointer: CGPoint?
    @State private var cursor = false
    @GestureState private var dragging = false
    var body: some View {
        let frame = model.albumFrame(page)
        AlbumArtwork(page: page, model: model, transmission: transmission, flare: flare, backlit: true)
            .overlay(Rectangle().stroke(model.showsSelection && model.selectedIDs.contains(page.id) ? Color.accentColor : .clear, lineWidth: 2))
            .scaleEffect(model.zoom)
            .frame(width: frame.width, height: frame.height)
            .contentShape(Rectangle())
            .onTapGesture { model.select(page.id, extending: !model.loupeEnabled && NSEvent.modifierFlags.contains(.command)) }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("table"))
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = page.position; startPan = model.pan; model.select(page.id, showIndicator: false) }
                    draggingID = page.id; pointer = value.location
                    if !cursor { NSCursor.closedHand.push(); cursor = true }
                    NSCursor.closedHand.set()
                    guard let origin = dragOrigin, let pan = startPan else { return }
                    model.updateAlbum(page.id) { $0.position = CGPoint(
                        x: origin.x + (value.translation.width + pan.x - model.pan.x) / model.zoom,
                        y: origin.y + (value.translation.height + pan.y - model.pan.y) / model.zoom) }
                }.onEnded { _ in endDrag() })
            .task(id: dragging) {
                guard dragging else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard let pointer else { continue }
                    let v = TableViewport.edgeVelocity(x: pointer.x, y: pointer.y - 64, width: model.boardSize.width, height: model.boardSize.height)
                    if v.x != 0 || v.y != 0 {
                        let delta = CGSize(width: v.x * 0.016, height: v.y * 0.016)
                        model.panBy(delta)
                        model.updateAlbum(page.id) {
                            if let p = $0.position { $0.position = CGPoint(x: p.x - delta.width / model.zoom, y: p.y - delta.height / model.zoom) }
                        }
                    }
                }
            }
            .onChange(of: dragging) { _, active in if !active { endDrag() } }
            .onDisappear { endDrag() }
            .contextMenu {
                Button("编辑相册页") { model.editingAlbumID = page.id; model.albumEditorPresented = true }
                Button(model.selectedIDs.contains(page.id) && model.selectedIDs.count > 1
                    ? "移出所选 \(model.selectedIDs.count) 项" : "整页收回相册") {
                    if !model.selectedIDs.contains(page.id) { model.select(page.id) }; model.removeSelected()
                }
            }
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel(page.name + "，\(page.photoCount) 张，整页移动")
            .accessibilityAddTraits(model.selectedIDs.contains(page.id) ? .isSelected : [])
    }
    private func endDrag() {
        dragOrigin = nil; startPan = nil; pointer = nil
        if cursor { NSCursor.pop(); cursor = false }
        if draggingID == page.id { draggingID = nil }
    }
}

struct AlbumEditor: View {
    @Bindable var model: TableModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: FilmFormat = .film135
    @State private var selectedPocket: UUID?
    @State private var note: String?
    @State private var deleting = false
    private var page: AlbumPage? { model.albums.first { $0.id == model.editingAlbumID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("胶片相册").font(.title3.weight(.medium))
                Spacer()
                if let page {
                    Button("整页放上观片台") { model.placeAlbum(page.id); dismiss() }
                        .disabled(page.photoCount == 0)
                }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                pageList.frame(width: 155)
                Divider()
                VStack(spacing: 10) {
                    if let page {
                        HStack {
                            TextField("相册页名称", text: Binding(get: { self.page?.name ?? "" }, set: { value in model.updateAlbum(page.id) { $0.name = value } }))
                                .textFieldStyle(.plain).font(.headline)
                            Text("\(page.photoCount) 张").foregroundStyle(.secondary)
                        }
                        HStack {
                            Picker("规格", selection: $format) {
                                Text("135 小格").tag(FilmFormat.film135)
                                Text("120 大格").tag(FilmFormat.film120)
                            }.pickerStyle(.segmented).frame(width: 210)
                            Button("加袋格") { addPocket() }
                            Menu("整页袋格") {
                                Button("135 · 5 × 4") { fill(.film135) }
                                Button("120 · 3 × 3") { fill(.film120) }
                            }.disabled(!page.pockets.isEmpty)
                        }
                        Text(note ?? "选袋格，再点右侧照片装入；拖动袋格换位，空白处点按添加。")
                            .font(.system(size: 11)).foregroundStyle(note == nil ? Color.secondary : Color.orange).lineLimit(2)
                        GeometryReader { proxy in
                            let scale = min(proxy.size.width / AlbumPage.size.width, proxy.size.height / AlbumPage.size.height)
                            editableSheet(page)
                                .scaleEffect(scale).frame(width: AlbumPage.size.width * scale, height: AlbumPage.size.height * scale)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        Spacer()
                        Text("新建一页，装入你的胶片").foregroundStyle(.secondary)
                        Button("新建相册页") { _ = model.newAlbum() }
                        Spacer()
                    }
                }.padding(16).frame(maxWidth: .infinity)
                Divider()
                library.frame(width: 216)
            }
        }.frame(width: min(1040, (NSScreen.main?.visibleFrame.width ?? 1100) - 48),
                height: min(780, (NSScreen.main?.visibleFrame.height ?? 840) - 48))
            .background(Color(white: 0.10))
            .environment(\.colorScheme, .dark)
            .onAppear { if model.editingAlbumID == nil { model.editingAlbumID = model.albums.first?.id } }
            .onChange(of: model.editingAlbumID) { _, _ in selectedPocket = nil; note = nil }
            .confirmationDialog("删除这一页？照片原文件会保留。", isPresented: $deleting) {
                Button("删除相册页", role: .destructive) { if let page { model.deleteAlbum(page.id) } }
            }
    }
    private var pageList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { _ = model.newAlbum(); selectedPocket = nil } label: { Label("新建页", systemImage: "plus") }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.albums) { item in
                        Button {
                            model.editingAlbumID = item.id
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).lineLimit(2)
                                Text("\(item.photoCount) 张\(item.position == nil ? "" : " · 台面上")").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(item.id == model.editingAlbumID ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if page != nil { Button("删除此页", role: .destructive) { deleting = true }.font(.caption) }
        }.padding(12)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("选择照片").font(.headline); Spacer(); Button(action: model.choosePhotos) { Image(systemName: "plus") } }
            Text(selectedPocket == nil ? "点照片装入下一个空袋格" : "点照片替换当前袋格").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(model.allPhotos) { photo in
                        Button { assign(photo.url) } label: { AlbumLibraryPhoto(photo: photo, model: model) }
                            .buttonStyle(.plain).onDrag { PhotoDrag.provider(for: photo) }.help(photo.name)
                    }
                }
            }
        }.padding(12)
    }
    private func editableSheet(_ page: AlbumPage) -> some View {
        AlbumArtwork(page: page, model: model, catalog: true)
            .background(Color(white: 0.22))
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                let col = Int(floor((point.x - AlbumPage.content.minX) / (AlbumPage.content.width / 15)))
                let row = Int(floor((point.y - AlbumPage.content.minY) / (AlbumPage.content.height / 12)))
                addPocket(column: col, row: row)
            }
            .overlay(alignment: .topLeading) {
                ForEach(page.pockets) { pocket in
                    let rect = AlbumPage.pocketRect(pocket)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .overlay(Rectangle().stroke(selectedPocket == pocket.id ? .white.opacity(0.8) : .clear, lineWidth: 1.5))
                        .overlay {
                            if pocket.url == nil {
                                VStack(spacing: 6) { Image(systemName: "plus"); Text(pocket.format.rawValue).font(.caption) }
                                    .foregroundStyle(.white.opacity(0.5)).allowsHitTesting(false)
                            }
                        }
                        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                        .onTapGesture { selectedPocket = pocket.id; note = nil }
                        .gesture(DragGesture(minimumDistance: 5).onEnded { value in
                            let col = pocket.column + Int((value.translation.width / (AlbumPage.content.width / 15)).rounded())
                            let row = pocket.row + Int((value.translation.height / (AlbumPage.content.height / 12)).rounded())
                            var moved = false
                            model.updateAlbum(page.id) { moved = $0.move(pocket.id, column: col, row: row) }
                            selectedPocket = pocket.id; note = moved ? nil : "这里放不下这个袋格，原位置已保留。"
                        })
                        .onDrop(of: [PhotoDrag.contentType], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            Task {
                                if let url = await PhotoDrag.sourceURL(from: provider), model.allPhotos.contains(where: { $0.url == url }) {
                                    model.updateAlbum(page.id) { $0.setPhoto(url, in: pocket.id) }; selectedPocket = pocket.id
                                }
                            }; return true
                        }
                        .contextMenu {
                            Button("清空照片") { model.updateAlbum(page.id) { $0.setPhoto(nil, in: pocket.id) } }
                            Button("移除袋格") { model.updateAlbum(page.id) { $0.remove(pocket.id) }; selectedPocket = nil }
                        }
                        .accessibilityLabel("\(pocket.format.rawValue) 袋格，第 \(pocket.row + 1) 行第 \(pocket.column + 1) 列")
                }
            }
    }
    private func addPocket(column: Int? = nil, row: Int? = nil) {
        guard let page else { return }
        var id: UUID?
        model.updateAlbum(page.id) { id = $0.add(format, column: column, row: row) }
        if let id { selectedPocket = id; note = nil }
        else { note = "这处没有足够空间，请移动或移除袋格，也可以新建一页。" }
    }
    private func fill(_ format: FilmFormat) {
        guard let page else { return }
        model.updateAlbum(page.id) { $0.fillEmptyPage(with: format) }
        selectedPocket = nil; note = nil
    }
    private func assign(_ url: URL) {
        guard let page else { return }
        var target = selectedPocket ?? page.pockets.first(where: { $0.url == nil })?.id
        model.updateAlbum(page.id) { page in
            if target == nil { target = page.add(format) }
            if let target { page.setPhoto(url, in: target) }
        }
        if target == nil { note = "这一页放不下了，请调整袋格或新建一页。" }
        else { note = nil; selectedPocket = nil }
    }
}

private struct AlbumLibraryPhoto: View {
    let photo: Photo
    let model: TableModel
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color(white: 0.06)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(3) }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(height: 76).contentShape(Rectangle())
            .task(id: photo.url) {
                image = model.thumbnails[photo.url] ?? PhotoThumbnailCache.cached(photo.url)
                if image == nil { image = await PhotoThumbnails.shared.thumbnail(photo.url) }
                if let image { model.cacheThumbnail(image, for: photo.url) }
            }
            .accessibilityLabel(photo.name)
    }
}
