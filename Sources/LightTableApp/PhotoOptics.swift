import CoreImage
import Foundation
import LightTableCore

/// SDR lamp and ignition response. Preserve source tones at the default setting.
enum PhotoOptics {
    private static let sdrRenderer = CIContext(options: [.workingColorSpace: blendSpace, .cacheIntermediates: false])
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    static let blendSpace = CGColorSpace(name: CGColorSpace.displayP3)!
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
            float light = dot(color.rgb, vec3(0.228975, 0.691739, 0.079287));
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
                float light = dot(result, vec3(0.228975, 0.691739, 0.079287));
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

    static func fusedOptical(_ image: CIImage, lampBrightness: Double, exposureStops: Double) -> CIImage {
        let gain = min(1.6, max(1, lampBrightness.isFinite ? lampBrightness : 1))

        // Skip if no-op
        guard gain > 1 || exposureStops > 0, let kernel = fusedOpticalKernel else {
            return image
        }

        let linear = image.applyingFilter("CISRGBToneCurveToLinear")
        let result = kernel.apply(extent: image.extent,
                                 arguments: [linear, gain, exposureStops]) ?? linear
        return result.applyingFilter("CILinearToSRGBToneCurve")
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
                          brightness: Double, transform: CGAffineTransform = .identity) -> CIImage {
        let dark = transform == .identity ? preview.darkCIImage : preview.darkCIImage.transformed(by: transform)
        if transmission <= 0 { return dark }

        // Cached variants contain scatter only. Apply the lamp's physical gain
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
        let gain = min(1.6, max(1, brightness.isFinite ? brightness : 1))
        guard gain > 1, let kernel = lampKernel else { return image }
        let linear = image.applyingFilter("CISRGBToneCurveToLinear")
        let powered = kernel.apply(extent: image.extent, arguments: [linear, gain]) ?? linear
        return powered.applyingFilter("CILinearToSRGBToneCurve")
    }

    static func ignition(_ image: CIImage, flare: Double, brightness: Double) -> CIImage {
        let stops = LightResponse.photoExposureStops(flare: flare, brightness: brightness)
        guard stops > 0, let kernel = ignitionKernel else { return image }
        let linear = image.applyingFilter("CISRGBToneCurveToLinear")
        let exposed = kernel.apply(extent: image.extent, arguments: [linear, stops]) ?? linear
        return exposed.applyingFilter("CILinearToSRGBToneCurve")
    }

    static func sdrImage(preview: PhotoPreview, transmission: Double, flare: Double, brightness: Double) -> CGImage? {
        let image = composite(preview: preview, transmission: transmission, flare: flare,
                              brightness: brightness)
        return sdrRenderer.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: blendSpace)
    }
}
