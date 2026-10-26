import AppKit
import SwiftUI

/// A separate presentation leaves the light table and its layout untouched.
struct ReturnToPastMode: View {
    @Bindable var model: TableModel
    @Bindable var session: ReturnToPastSession
    @State private var targeted = false
    @State private var dropID = UUID()
    @State private var presentationReady = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: exit) {
                    Label("返回观片台", systemImage: "arrow.left")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 17).frame(height: 38)
                        .background(.white.opacity(0.09), in: Capsule())
                }.buttonStyle(.plain)
                Text("回到过去").font(.system(size: 13, weight: .medium))
                if let source = session.sourceURL {
                    Text(source.lastPathComponent).font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                if session.phase == .playing {
                    Button("复位视角") { session.resetView() }.buttonStyle(.plain)
                }
                if session.isActive {
                    Button(session.canPlay ? "收回胶片" : "取消") {
                        dropID = UUID(); session.close()
                    }.buttonStyle(.plain)
                }
            }
            .foregroundStyle(.white.opacity(0.85)).padding(20)

            GeometryReader { proxy in
                ZStack {
                    Color.black
                    if session.isActive {
                        let aspect = session.scene.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.5
                        let width = min(proxy.size.width, proxy.size.height * aspect)
                        ReturnToPastPlayer(session: session)
                            .frame(width: width, height: width / aspect)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 30, weight: .ultraLight))
                            Text("从下方拖一张胶片到这里").font(.system(size: 14))
                            Text("生成完成后，这一刻会从黑暗中慢慢浮现")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                        }.foregroundStyle(.white.opacity(0.85))
                    }
                    if targeted {
                        Rectangle().strokeBorder(.white.opacity(0.65), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [PhotoDrag.contentType], isTargeted: $targeted, perform: accept)
                .accessibilityLabel("回到过去播放区")
                .accessibilityHint("拖入底栏照片开始生成，也可通过底栏照片的辅助操作放入")
            }
            .padding(.horizontal, 20)
            filmTray.padding(16)
        }
        .background(.black).environment(\.colorScheme, .dark)
        .background {
            SlideshowWindow(ready: true, next: {}, previous: {}, exit: exit,
                            presentationReady: { presentationReady = true })
                .frame(width: 0, height: 0)
        }
        .onDisappear { dropID = UUID(); session.close() }
    }

    private var filmTray: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: model.chooseFolder) {
                    Label("从文件夹导入", systemImage: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Color(white: 0.22), in: Capsule())
                }.buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.trays) { tray in
                            Button { model.selectTray(tray.id) } label: {
                                Text(tray.name).font(.system(size: 11))
                                    .lineLimit(1).padding(.horizontal, 10).frame(height: 28)
                                    .background(model.activeTrayID == tray.id ? Color(white: 0.22) : .clear,
                                                in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxWidth: 280)
                Text("\(model.photos.count) 张").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                if model.isImporting { ProgressView().controlSize(.small) }
                Spacer()
            }
            if model.photos.isEmpty {
                Text("先导入照片，再拖到上方播放区")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 0) {
                        ForEach(model.photos) { photo in
                            ReturnToPastTrayPhoto(photo: photo, model: model,
                                selected: session.sourceURL == photo.url,
                                place: { start(photo.url) })
                        }
                    }.padding(.bottom, 3)
                }.frame(height: 88).id(model.activeTrayID)
            }
        }
        .foregroundStyle(.white.opacity(0.92)).padding(14)
        .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 16))
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard presentationReady,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(PhotoDrag.contentType.identifier)
              }) else { return false }
        let request = UUID()
        dropID = request
        Task { @MainActor in
            guard let source = await PhotoDrag.sourceURL(from: provider),
                  dropID == request, model.returnToPastMode,
                  model.allPhotos.contains(where: { $0.url.standardizedFileURL == source }) else { return }
            start(source)
        }
        return true
    }

    private func start(_ source: URL) {
        guard model.returnToPastMode, presentationReady else { return }
        dropID = UUID()
        session.start(slideID: UUID(), source: source,
                      aperture: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func exit() {
        dropID = UUID(); session.close(); model.returnToPastMode = false
    }
}

private struct ReturnToPastTrayPhoto: View {
    let photo: Photo
    @Bindable var model: TableModel
    let selected: Bool
    let place: () -> Void
    @State private var image: CGImage?
    @State private var loaded = false
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 5) {
            FilmSleeve(image: image, failed: loaded && image == nil,
                       highlighted: selected || hovered, lifted: false)
                .onDrag { PhotoDrag.provider(for: photo) }
            Text(photo.name).font(.system(size: 9)).lineLimit(1)
                .frame(width: 94).padding(.horizontal, 5)
        }
        .help("\(photo.name)；拖到上方播放区")
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(photo.name)
        .accessibilityHint("放入播放区，从原始照片生成三维场景")
        .accessibilityAction(named: Text("放入播放区"), place)
        .task(id: photo.url) {
            image = model.thumbnails[photo.url] ?? PhotoThumbnailCache.cached(photo.url)
            if image == nil { image = await PhotoThumbnails.shared.thumbnail(photo.url) }
            if let image { model.cacheThumbnail(image, for: photo.url) }
            loaded = true
        }
    }
}
