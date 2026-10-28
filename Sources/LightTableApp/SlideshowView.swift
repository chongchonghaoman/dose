import SwiftUI

struct SlideshowView: View {
    @Bindable var model: TableModel
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playback = makePlayback()
    @State private var presentationReady = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if let photo = playback.photo {
                    let size = photo.fittedSize(in: proxy.size)
                    SlideshowPhotoDisplay(photo: photo, focus: playback.focus, brightness: model.edrBrightness)
                    .frame(width: size.width, height: size.height)
                    .modifier(ProjectionTravel(progress: playback.transport, container: proxy.size, image: size))
                    .opacity(playback.shutter)
                    .accessibilityLabel("幻灯投影")
                }
                if presentationReady && playback.failed {
                    VStack(spacing: 16) {
                        Text("这张照片暂时无法读取").foregroundStyle(.white.opacity(0.7))
                        HStack(spacing: 20) {
                            Button("重试") { loadCurrent() }
                            Button("下一张", action: model.nextSlide)
                        }.buttonStyle(.plain).foregroundStyle(.white)
                    }.font(.system(size: 13))
                } else if presentationReady && playback.loadingHint {
                    ProgressView().controlSize(.small).tint(.white)
                }
                VStack {
                    HStack {
                        Button(action: model.exitSlideshow) {
                            Label("返回观片台", systemImage: "arrow.left")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 17).frame(height: 38)
                                .foregroundStyle(.white.opacity(0.8))
                                .background(Color.white.opacity(0.09), in: Capsule())
                        }.buttonStyle(.plain).padding(20)
                        Spacer()
                    }
                    Spacer()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }
        .background {
            SlideshowWindow(ready: ready, next: model.nextSlide, previous: model.previousSlide,
                            exit: model.exitSlideshow, presentationReady: {
                presentationReady = true
                playback.beginPresentation()
            }).frame(width: 0, height: 0)
        }
        .onChange(of: model.currentSlideURL, initial: true) { _, _ in loadCurrent() }
        .task(id: playback.photo?.url) {
            guard playback.photo?.url == model.currentSlideURL, let next = model.nextSlideURL,
                  next != model.currentSlideURL else { return }
            _ = await SlideshowProjectionStore.shared.photo(next)
        }
        .onDisappear { playback.cancel() }
    }

    private func loadCurrent() {
        if let url = model.currentSlideURL { playback.show(url, reduceMotion: reduceMotion) }
    }

    @MainActor private static func makePlayback() -> SlideshowPlayback {
        let sound = SlideshowMechanicalSound()
        return SlideshowPlayback(outgoingSound: { sound.outgoing() },
                                 firstArrivalSound: { sound.firstArrival() },
                                 prepareSound: { await sound.prepare() }, stopSound: { sound.stop() })
    }
}

/// Animate focus inside the EDR surface instead of flattening two HDR views
/// into a SwiftUI bitmap. Table EDR preferences remain independent.
struct SlideshowPhotoDisplay: View, Animatable {
    let photo: ProjectionPhoto
    var focus: Double
    let brightness: Double

    var animatableData: Double {
        get { focus }
        set { focus = newValue }
    }

    var body: some View {
        OpticalDisplay(preview: photo.preview, brightness: brightness,
                       edrEnabled: true, defocusedPreview: photo.defocusedPreview, focus: focus)
    }
}
