import CoreImage
import Foundation
import Metal
import LightTableCore
import LightTableEDR

/// Shared lamp response with optional display-referred EDR transmission.
enum PhotoOptics {
    static let transmissionExposureGain = 1.101531648960814
    private static let sdrRenderer = CIContext(options: [.workingColorSpace: linearSpace, .cacheIntermediates: false])
    static let edrRenderer: CIContext? = MTLCreateSystemDefaultDevice().map {
        CIContext(mtlDevice: $0, options: [.workingColorSpace: linearSpace, .cacheIntermediates: false])
    }
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let blendSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let lampKernel = CIColorKernel(source: """
        kernel vec4 lampTransmission(__sample color, float gain) {
            float sourcePeak = max(color.r, max(color.g, color.b));
            float peak = sourcePeak * gain;
            float knee = 0.80;
            float room = 0.20;
            float excess = max(0.0, peak - knee);
            float shoulder = knee + room * excess / (room + excess);
            float outputPeak = peak > knee ? max(sourcePeak, shoulder) : peak;
            return vec4(color.rgb * (sourcePeak > 0.0 ? outputPeak / sourcePeak : gain), color.a);
        }
        """)
    static let ignitionKernel = CIColorKernel(source: """
        kernel vec4 ignitionExposure(__sample color, float stops) {
            float light = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
            float protection = smoothstep(0.004, 0.075, light);
            float sourcePeak = max(color.r, max(color.g, color.b));
            float peak = sourcePeak * exp2(stops * protection);
            float excess = max(0.0, peak - 0.85);
            float shoulder = 0.85 + 0.15 * excess / (0.15 + excess);
            float outputPeak = peak > 0.85 ? max(sourcePeak, shoulder) : peak;
            return vec4(color.rgb * (sourcePeak > 0.0 ? outputPeak / sourcePeak : 1.0), color.a);
        }
        """)
    // Lamp gain and ignition share one linear-light pass.
    static let fusedOpticalKernel = CIColorKernel(source: """
        kernel vec4 fusedOptical(__sample color, float lampGain, float exposureStops) {
            vec3 result = color.rgb;

            // Lamp power stays within ordinary display white.
            if (lampGain > 1.0) {
                float sourcePeak = max(result.r, max(result.g, result.b));
                float peak = sourcePeak * lampGain;
                float knee = 0.80;
                float room = 0.20;
                float excess = max(0.0, peak - knee);
                float shoulder = knee + room * excess / (room + excess);
                float outputPeak = peak > knee ? max(sourcePeak, shoulder) : peak;
                result *= (sourcePeak > 0.0 ? outputPeak / sourcePeak : lampGain);
            }

            // Transient shoulder protects highlight hue from SDR channel clipping.
            if (exposureStops > 0.0) {
                float light = dot(result, vec3(0.2126, 0.7152, 0.0722));
                float protection = smoothstep(0.004, 0.075, light);
                float sourcePeak = max(result.r, max(result.g, result.b));
                float peak = sourcePeak * exp2(exposureStops * protection);
                float excess = max(0.0, peak - 0.85);
                float shoulder = 0.85 + 0.15 * excess / (0.15 + excess);
                float outputPeak = peak > 0.85 ? max(sourcePeak, shoulder) : peak;
                result *= (sourcePeak > 0.0 ? outputPeak / sourcePeak : 1.0);
            }

            return vec4(result, color.a);
        }
        """)
    /// Display limits and EDR response are provided by the binary component.
    static func boundedEDRHeadroom(_ value: Double) -> Double {
        LTEDRHeadroom(value)
    }

    static func fusedOptical(_ image: CIImage, lampBrightness: Double, exposureStops: Double) -> CIImage {
        let power = min(1.6, max(1, lampBrightness.isFinite ? lampBrightness : 1))
        let gain = power * transmissionExposureGain

        // Skip if no-op
        guard gain > 1 || exposureStops > 0, let kernel = fusedOpticalKernel else {
            return image
        }

        return kernel.apply(extent: image.extent,
                            arguments: [image, gain, exposureStops]) ?? image
    }

    static func mix(_ from: CIImage, _ to: CIImage, _ amount: Double) -> CIImage {
        if amount <= 0 { return from }
        if amount >= 1 { return to }
        return from.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: to, kCIInputTimeKey: amount])
    }

    static func multiplied(_ image: CIImage, _ level: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: level, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: level, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: level, w: 0)])
    }

    static func composite(preview: PhotoPreview, transmission: Double, flare: Double,
                          brightness: Double, transform: CGAffineTransform = .identity,
                          edrEnabled: Bool = false, edrHeadroom: Double = 1, litImage: CIImage? = nil,
                          boostedImage: CIImage? = nil) -> CIImage {
        let dark = transform == .identity ? preview.darkCIImage : preview.darkCIImage.transformed(by: transform)
        if transmission <= 0 { return dark }

        if edrEnabled {
            let sourceLit = litImage ?? preview.litCIImage
            let rawBase = preview.transmitted ? mix(sourceLit, boostedImage ?? preview.boostedCIImage,
                LightResponse.photoBrightnessMix(brightness: brightness)) : sourceLit
            let rawHalo = preview.flareCIImage.applyingFilter("CIScreenBlendMode", parameters: [
                kCIInputBackgroundImageKey: rawBase
            ])
            let rawStable = multiplied(mix(rawBase, rawHalo,
                LightResponse.photoGlowMix(flare: flare, brightness: brightness)),
                LightResponse.photoLevel(brightness: brightness))
            let stops = LightResponse.photoExposureStops(flare: flare, brightness: brightness)
            let power = min(1.6, max(1, brightness.isFinite ? brightness : 1))
            let rawLit = boundedEDRHeadroom(edrHeadroom) > 1 && LTEDRIsReady()
                ? LTEDRCompose(rawStable, power * transmissionExposureGain, stops, edrHeadroom)
                : fusedOptical(rawStable, lampBrightness: brightness, exposureStops: stops)
            let lit = transform == .identity ? rawLit : rawLit.transformed(by: transform)
            return mix(dark, lit, min(1, max(0, transmission)))
        }

        // Cached variants contain the steady tone response and local scatter.
        // Apply the lamp's gain
        // here in float linear light, before display clipping can discard it.
        let rawBase = preview.transmitted ? mix(preview.litCIImage, preview.boostedCIImage,
                       LightResponse.photoBrightnessMix(brightness: brightness)) : preview.litCIImage
        let rawHalo = preview.flareCIImage.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: rawBase])
        let rawStable = multiplied(mix(rawBase, rawHalo, LightResponse.photoGlowMix(flare: flare, brightness: brightness)),
                                LightResponse.photoLevel(brightness: brightness))
        let exposureStops = LightResponse.photoExposureStops(flare: flare, brightness: brightness)
        let rawLit = fusedOptical(rawStable, lampBrightness: brightness,
                              exposureStops: exposureStops)

        let lit = transform == .identity ? rawLit : rawLit.transformed(by: transform)

        return mix(dark, lit, min(1, max(0, transmission)))
    }

    static func lamp(_ image: CIImage, brightness: Double) -> CIImage {
        let power = min(1.6, max(1, brightness.isFinite ? brightness : 1))
        let gain = power * transmissionExposureGain
        guard gain > 1, let kernel = lampKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, gain]) ?? image
    }

    static func ignition(_ image: CIImage, flare: Double, brightness: Double) -> CIImage {
        let stops = LightResponse.photoExposureStops(flare: flare, brightness: brightness)
        guard stops > 0, let kernel = ignitionKernel else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, stops]) ?? image
    }

    static func sdrImage(preview: PhotoPreview, transmission: Double, flare: Double, brightness: Double) -> CGImage? {
        let image = composite(preview: preview, transmission: transmission, flare: flare,
                              brightness: brightness)
        return sdrRenderer.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: blendSpace)
    }
}
