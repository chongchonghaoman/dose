import CoreGraphics
import Foundation
import LightTableCore
import SwiftUI

struct SlideshowEntryPhoto: Identifiable {
    let url: URL
    let image: CGImage
    let frame: CGRect
    var startingAngle: Double = 0
    var colorMultiplier: Double = 1
    var id: URL { url }
}

struct SlideshowEntrySource {
    let url: URL
    let image: CGImage?
    let frame: CGRect
    var startingAngle: Double = 0
    var colorMultiplier: Double = 1

    @MainActor static func prepare(_ sources: [Self],
                                  load: (URL) async -> CGImage?) async throws -> [SlideshowEntryPhoto] {
        var photos: [SlideshowEntryPhoto] = []
        for source in sources {
            try Task.checkCancellation()
            let image: CGImage?
            if let cached = source.image { image = cached }
            else { image = await load(source.url) }
            try Task.checkCancellation()
            guard let image else { continue }
            // Retain each image in this presentation, independently of cache eviction.
            photos.append(SlideshowEntryPhoto(url: source.url, image: image, frame: source.frame,
                                               startingAngle: source.startingAngle,
                                               colorMultiplier: source.colorMultiplier))
        }
        return photos
    }
}

extension TableModel {
    func slideshowCanvasSources(in canvasBounds: CGRect) -> [SlideshowEntrySource] {
        guard canvasBounds.width > 1, canvasBounds.height > 1 else { return [] }
        return layout.slides.compactMap { slide in
            let preview = preparedTablePreviews[slide.url] ?? preparedPreviews[slide.url]
            // Keep the unlit canvas raster; a flight must not switch on the film.
            let image = (isLit ? preview?.source : preview?.dark) ?? thumbnails[slide.url]
            let aspect = preview.map { Double($0.aspect) }
                ?? image.map { Double($0.width) / Double($0.height) }
                ?? imageAspects[slide.url] ?? 1.5
            let placement = screenPlacement(slide, aspect: aspect)
            let center = CGPoint(x: canvasBounds.minX + placement.x,
                                 y: canvasBounds.minY + 64 + placement.y)
            let frame = CGRect(x: center.x - placement.width / 2, y: center.y - placement.height / 2,
                               width: placement.width, height: placement.height)
            let radians = placement.angle * .pi / 180
            let rotatedSize = CGSize(width: placement.width * abs(cos(radians)) + placement.height * abs(sin(radians)),
                                     height: placement.width * abs(sin(radians)) + placement.height * abs(cos(radians)))
            let visibleBounds = CGRect(x: center.x - rotatedSize.width / 2, y: center.y - rotatedSize.height / 2,
                                       width: rotatedSize.width, height: rotatedSize.height)
            guard frame.width > 1, frame.height > 1, visibleBounds.intersects(canvasBounds) else { return nil }
            return SlideshowEntrySource(url: slide.url, image: image, frame: frame, startingAngle: placement.angle,
                                        colorMultiplier: !isLit && preview == nil ? 0.10 : 1)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }
}

struct SlideshowEntry: View {
    let photos: [SlideshowEntryPhoto]
    let reduceMotion: Bool
    let onFeed: () -> Void
    let completion: () -> Void

    @State private var blackOpacity = 0.0
    @State private var boxOpacity = 0.0
    @State private var departing: Set<URL> = []
    @State private var activeRun: UUID?
    @State private var completed = false

    init(photos: [SlideshowEntryPhoto], reduceMotion: Bool,
         onFeed: @escaping () -> Void = {}, completion: @escaping () -> Void) {
        self.photos = photos
        self.reduceMotion = reduceMotion
        self.onFeed = onFeed
        self.completion = completion
    }

    var body: some View {
        GeometryReader { proxy in
            let boxCenter = CGPoint(x: proxy.size.width / 2,
                                    y: max(70, min(proxy.size.height - 130, proxy.size.height * 0.62)))
            let destination = CGPoint(x: boxCenter.x, y: boxCenter.y + 3)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(reduceMotion ? 1 : blackOpacity)
                if !reduceMotion {
                    SlideshowEntryBoxBack()
                        .frame(width: 138, height: 84)
                        .position(boxCenter)
                        .opacity(boxOpacity)
                    cards(destination: destination, foreground: false)
                    SlideshowEntryBoxFront()
                        .frame(width: 138, height: 84)
                        .position(boxCenter)
                        .opacity(boxOpacity)
                    cards(destination: destination, foreground: true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
        }
        .accessibilityHidden(true)
        .task { await animateCollection() }
        .onDisappear { activeRun = nil }
    }

    private func cards(destination: CGPoint, foreground: Bool) -> some View {
        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
            SlideshowEntryCard(photo: photo)
                .modifier(SlideshowEntryFlight(frame: photo.frame, index: index,
                    destination: destination, foreground: foreground,
                    startingAngle: photo.startingAngle,
                    progress: departing.contains(photo.id) ? 1 : 0))
        }
    }

    @MainActor private func animateCollection() async {
        guard !completed else { return }
        let run = UUID()
        activeRun = run
        guard !reduceMotion, !photos.isEmpty else {
            finish(run)
            return
        }
        do {
            // Commit the real sleeve positions before starting any animation.
            try await Task.sleep(for: .milliseconds(32))
            guard activeRun == run, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.26)) { blackOpacity = 0.91 }
            withAnimation(.easeOut(duration: 0.18)) { boxOpacity = 1 }
            try await Task.sleep(for: .milliseconds(120))
            guard activeRun == run, !Task.isCancelled else { return }
            // Independent property animations keep each film visible for its
            // entire flight. The front panel only covers its final descent.
            let spacing = min(0.09, 0.99 / Double(max(1, photos.count - 1)))
            await withTaskGroup(of: Void.self) { group in
                for (index, photo) in photos.enumerated() {
                    group.addTask { @MainActor in
                        do {
                            try await Task.sleep(for: .seconds(Double(index) * spacing))
                            guard activeRun == run, !Task.isCancelled else { return }
                            withAnimation(.timingCurve(0.35, 0.02, 0.52, 1, duration: 0.72)) {
                                _ = departing.insert(photo.id)
                            }
                            try await Task.sleep(for: .milliseconds(660))
                            guard activeRun == run, !Task.isCancelled else { return }
                            onFeed()
                        } catch { return }
                    }
                }
                await group.waitForAll()
            }
            try await Task.sleep(for: .milliseconds(100))
            guard activeRun == run, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                blackOpacity = 1
                boxOpacity = 0
            }
            try await Task.sleep(for: .milliseconds(200))
        } catch { return }
        finish(run)
    }

    @MainActor private func finish(_ run: UUID) {
        guard activeRun == run, !Task.isCancelled, !completed else { return }
        completed = true
        completion()
    }
}

private struct SlideshowEntryCard: View {
    let photo: SlideshowEntryPhoto

    var body: some View {
        Image(decorative: photo.image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .scaledToFit()
            .frame(width: photo.frame.width, height: photo.frame.height)
            .colorMultiply(Color(white: photo.colorMultiplier))
            .background(Color(white: 0.055))
            .clipShape(RoundedRectangle(cornerRadius: 1.5))
            .overlay(RoundedRectangle(cornerRadius: 1.5)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Pure geometry: no image filters or continuing animation clock.
struct SlideshowEntryPose {
    let center: CGPoint
    let scale: CGFloat
    let angle: Double
    let tilt: Double
    let behindFront: Bool
    let opacity: Double

    init(frame: CGRect, destination: CGPoint, index: Int, progress: Double, startingAngle: Double = 0) {
        let t = min(1, max(0, progress))
        let p = CGFloat(t)
        let q = 1 - p
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let rise = min(150, max(90, abs(start.y - destination.y) * 0.60))
        let highY = min(start.y, destination.y) - rise
        let bend: CGFloat = start.x < destination.x ? -24 : 24
        let first = CGPoint(x: start.x + bend, y: highY)
        let second = CGPoint(x: destination.x + (start.x - destination.x) * 0.16, y: highY)
        center = CGPoint(x: q * q * q * start.x + 3 * q * q * p * first.x
                             + 3 * q * p * p * second.x + p * p * p * destination.x,
                         y: q * q * q * start.y + 3 * q * q * p * first.y
                             + 3 * q * p * p * second.y + p * p * p * destination.y)
        let eased = t * t * (3 - 2 * t)
        scale = CGFloat(1 - 0.28 * eased)
        angle = startingAngle + Double(index % 5 - 2) * 3 * sin(.pi * t)
        tilt = 58 * eased
        behindFront = t >= 0.84
        opacity = min(1, max(0, (1 - t) / 0.03))
    }
}

private struct SlideshowEntryFlight: AnimatableModifier {
    let frame: CGRect
    let index: Int
    let destination: CGPoint
    let foreground: Bool
    let startingAngle: Double
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = SlideshowEntryPose(frame: frame, destination: destination, index: index,
                                      progress: progress, startingAngle: startingAngle)
        content
            .rotationEffect(.degrees(pose.angle))
            .rotation3DEffect(.degrees(pose.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.25)
            .scaleEffect(pose.scale)
            .position(pose.center)
            .opacity(foreground != pose.behindFront ? pose.opacity : 0)
    }
}

private struct SlideshowEntryBoxBack: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(white: 0.12))
                .frame(width: 130, height: 54).offset(y: 7)
            SlideshowEntryBoxTop()
                .fill(LinearGradient(colors: [Color(white: 0.23), Color(white: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 130, height: 27).offset(y: -23)
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(white: 0.34 - Double(index) * 0.05))
                    .frame(width: 80 - CGFloat(index) * 2, height: 2)
                    .offset(x: CGFloat(index - 1), y: -24 - CGFloat(index) * 1.4)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black)
                .frame(width: 86, height: 5).offset(y: -20)
        }
    }
}

private struct SlideshowEntryBoxFront: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.085)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.7))
                .frame(width: 130, height: 43).offset(y: 8)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.16))
                .frame(width: 105, height: 25).offset(y: 10)
            Capsule().fill(Color.white.opacity(0.12))
                .frame(width: 28, height: 1).offset(y: -3)
        }
    }
}

private struct SlideshowEntryBoxTop: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.11, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.width * 0.89, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
