import CoreImage
import Foundation
import LightTableCore

struct LoupeSceneInput: Equatable {
    let photos: [LoupeScenePhoto]
    let point: CGPoint
    let panelBounds: CGRect?
    let transmission: Double
    let flare: Double
    let brightness: Double
}

/// One immutable snapshot for the live drawable. No asynchronously returned bitmap.
struct LoupeDisplayInput: Equatable {
    let scene: LoupeSceneInput
    let diameter: CGFloat
    let magnification: CGFloat
    let displayScale: CGFloat
    // Top-left coordinates within the full optical square. Render only pixels
    // visible in the window, while preserving the lens's original optical axis.
    var viewport: CGRect? = nil
    var refractionScale: CGFloat = 1

    var pixelSize: CGSize {
        let size = viewport?.size ?? CGSize(width: diameter, height: diameter)
        let scale = max(1, min(3, displayScale))
        return CGSize(width: ceil(size.width * scale), height: ceil(size.height * scale))
    }
}

/// A film's geometry in the same top-left coordinate system as the table.
struct LoupeScenePhoto: Equatable {
    let preview: PhotoPreview?
    var thumbnail: CGImage? = nil
    let center: CGPoint
    let imageSize: CGSize
    var angle: Double = 0
    var mountScale: CGFloat = 1
    var mountInsets = CGSize.zero
    var surface: CGImage? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.center == rhs.center && lhs.imageSize == rhs.imageSize && lhs.angle == rhs.angle && lhs.mountScale == rhs.mountScale && lhs.mountInsets == rhs.mountInsets && lhs.surface === rhs.surface &&
        lhs.thumbnail === rhs.thumbnail && lhs.preview?.source === rhs.preview?.source &&
        lhs.preview?.lit === rhs.preview?.lit && lhs.preview?.dark === rhs.preview?.dark &&
        lhs.preview?.flare === rhs.preview?.flare && lhs.preview?.boosted === rhs.preview?.boosted &&
        lhs.preview?.transmitted == rhs.preview?.transmitted
    }

    var bounds: CGRect {
        let radians = angle * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let w = (imageSize.width + 2 * mountInsets.width * mountScale) * c + (imageSize.height + 2 * mountInsets.height * mountScale) * s
        let h = (imageSize.width + 2 * mountInsets.width * mountScale) * s + (imageSize.height + 2 * mountInsets.height * mountScale) * c
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
}

/// Render only the small lens viewport. Refraction lives in the outer glass
/// annulus; the centre keeps its original detail and pointer alignment.
final class LoupeRenderer {
    static let shared = LoupeRenderer()
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    // Convert tagged original and processed previews to the same display space.
    // Nonlinear P3 keeps light blending aligned with the SwiftUI table layers.
    private let context = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])
    // A bounded, monotonic radial warp: no torus, foldover, or sampled ring.
    // Keep the central 90% straight. The narrow lip displaces at most 0.6%
    // of the radius, and fades as the eye passes through the lens.
    private let edgeKernel = CIWarpKernel(source: """
        kernel vec2 loupeEdge(vec2 centre, float radius, float strength) {
            vec2 delta = destCoord() - centre;
            float distance = length(delta);
            float r = distance / radius;
            float shoulder = smoothstep(0.90, 1.0, r);
            float lip = smoothstep(0.97, 1.0, r);
            float inset = radius * (0.0045 * shoulder + 0.0015 * lip) * strength;
            return centre + delta * (1.0 - inset / max(distance, 0.001));
        }
        """)

    static func sourceViewport(point: CGPoint, diameter: CGFloat, magnification: CGFloat) -> CGRect {
        let radius = diameter / (2 * max(1, magnification)) + 2
        return CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    // Retained for single-photo render checks; production uses the whole scene.
    func render(preview: PhotoPreview, point: CGPoint, imageSize: CGSize,
                diameter: CGFloat, magnification: CGFloat, displayScale: CGFloat,
                transmission: Double, flare: Double, brightness: Double,
                refracts: Bool = true) -> CGImage? {
        render(photos: [LoupeScenePhoto(preview: preview,
            center: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2), imageSize: imageSize)],
            point: point, diameter: diameter, magnification: magnification, displayScale: displayScale,
            transmission: transmission, flare: flare, brightness: brightness, refracts: refracts)
    }

    func render(photos: [LoupeScenePhoto], point: CGPoint, panelBounds: CGRect? = nil,
                diameter: CGFloat, magnification: CGFloat, displayScale: CGFloat,
                transmission: Double, flare: Double, brightness: Double,
                refracts: Bool = true, opticalDiameter: CGFloat? = nil,
                viewport: CGRect? = nil, refractionScale: CGFloat = 1) -> CGImage? {
        guard let glass = composite(photos: photos, point: point, panelBounds: panelBounds,
            diameter: diameter, magnification: magnification, displayScale: displayScale,
            transmission: transmission, flare: flare, brightness: brightness,
            refracts: refracts, opticalDiameter: opticalDiameter,
            viewport: viewport, refractionScale: refractionScale) else { return nil }
        return context.createCGImage(glass, from: glass.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// Build a lazy Core Image graph and encode it directly into the Metal drawable.
    /// The former CGImage readback/upload introduced an independent, late image clock.
    func composite(photos: [LoupeScenePhoto], point: CGPoint, panelBounds: CGRect? = nil,
                   diameter: CGFloat, magnification: CGFloat, displayScale: CGFloat,
                   transmission: Double, flare: Double, brightness: Double,
                   refracts: Bool = true, opticalDiameter: CGFloat? = nil,
                   viewport: CGRect? = nil, refractionScale: CGFloat = 1) -> CIImage? {
        guard diameter > 0, magnification > 0 else { return nil }
        let scale = max(1, min(3, displayScale))
        let pixels = ceil(diameter * scale)
        let radius = pixels / 2
        let region = viewport ?? CGRect(x: 0, y: 0, width: diameter, height: diameter)
        guard region.width > 0, region.height > 0 else { return nil }
        let centre = CGPoint(x: radius - region.minX * scale,
                             y: radius - (diameter - region.maxY) * scale)
        let opticalRadius = (opticalDiameter ?? diameter) * scale / 2
        let output = CGRect(x: 0, y: 0, width: ceil(region.width * scale), height: ceil(region.height * scale))
        let factor = magnification * scale
        let sourceViewport = CGRect(x: point.x + (region.minX - diameter / 2) / magnification,
                                    y: point.y + (region.minY - diameter / 2) / magnification,
                                    width: region.width / magnification, height: region.height / magnification)
            .insetBy(dx: -2, dy: -2)
        let light = min(1, max(0, transmission))
        let white = LightResponse.panelWhite(brightness: brightness, flare: flare)
        let panel = CIImage(color: CIColor(red: 0.89 * (1 - light) + white * light,
                                           green: 0.85 * (1 - light) + white * light,
                                           blue: 0.75 * (1 - light) + white * light))
        let black = CIImage(color: CIColor(red: 0.025, green: 0.025, blue: 0.025))
        let panelRect = panelBounds.map {
            CGRect(x: centre.x + ($0.minX - point.x) * factor,
                   y: centre.y - ($0.maxY - point.y) * factor,
                   width: $0.width * factor, height: $0.height * factor)
        }
        var scene = panelRect.map { panel.cropped(to: $0).composited(over: black) } ?? panel
        // Preserve table order, rotation, mounts and gaps. The pointer need
        // not hit a photograph: all films inside the sampled viewport count.
        for item in photos where item.bounds.intersects(sourceViewport) {
            guard item.imageSize.width > 0, item.imageSize.height > 0 else { continue }
            let w = item.imageSize.width, h = item.imageSize.height
            let radians = item.angle * .pi / 180
            let c = cos(radians), s = sin(radians)
            let cx = centre.x + (item.center.x - point.x) * factor
            let cy = centre.y - (item.center.y - point.y) * factor
            let localToLens = CGAffineTransform(a: c * factor, b: -s * factor,
                c: s * factor, d: c * factor,
                tx: cx - (c * w + s * h) * factor / 2,
                ty: cy + (s * w - c * h) * factor / 2)
            if let surface = item.surface {
                let sourceToLens = CGAffineTransform(
                    scaleX: w / CGFloat(surface.width), y: h / CGFloat(surface.height))
                    .concatenating(localToLens)
                scene = CIImage(cgImage: surface).transformed(by: sourceToLens).composited(over: scene)
                continue
            }
            let dx = item.mountInsets.width * item.mountScale, dy = item.mountInsets.height * item.mountScale
            let mount = black.cropped(to: CGRect(x: -dx, y: -dy, width: w + 2 * dx, height: h + 2 * dy))
                .transformed(by: localToLens)
            var film = mount
            if let preview = item.preview {
                let sourceToLens = CGAffineTransform(
                    scaleX: w / CGFloat(preview.sourceCIImage.extent.width),
                    y: h / CGFloat(preview.sourceCIImage.extent.height))
                    .concatenating(localToLens)
                film = PhotoOptics.composite(preview: preview, transmission: light, flare: flare,
                    brightness: brightness, transform: sourceToLens).composited(over: mount)
            } else if let thumbnail = item.thumbnail {
                let sourceToLens = CGAffineTransform(
                    scaleX: w / CGFloat(thumbnail.width), y: h / CGFloat(thumbnail.height))
                    .concatenating(localToLens)
                film = PhotoOptics.multiplied(CIImage(cgImage: thumbnail).transformed(by: sourceToLens),
                    0.10 + 0.90 * light).composited(over: mount)
            }
            scene = film.composited(over: scene)
        }
        if let panelRect {
            scene = scene.cropped(to: panelRect).composited(over: black)
        }
        let glass: CIImage
        if refracts, refractionScale > 0, let edgeKernel {
            glass = edgeKernel.apply(extent: output, roiCallback: { _, rect in
                rect.insetBy(dx: -opticalRadius * 0.007, dy: -opticalRadius * 0.007)
            }, image: scene, arguments: [CIVector(cgPoint: centre), opticalRadius,
                                        min(1, max(0, refractionScale))]) ?? scene
        } else {
            glass = scene
        }
        return glass.cropped(to: output)
    }
}
