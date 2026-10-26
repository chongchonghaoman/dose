import Foundation

/// Unitless contributions shared by lamp, photographs and loupe.
/// Art-directed display response, not a calibrated light/eye model.
public struct LightResponseSample: Equatable, Sendable {
    public let transmission: Double
    public let flare: Double
    public let glow: Double

    public init(transmission: Double, flare: Double, glow: Double) {
        self.transmission = transmission
        self.flare = flare
        self.glow = glow
    }
}

public enum LightResponse {
    // Shared by the tabletop and the lens so their unlit surfaces match.
    public static let unlitPanel = (red: 0.84, green: 0.81, blue: 0.70)
    public static let lampRiseDuration: TimeInterval = 0.12
    public static let peakTime: TimeInterval = 0.16
    public static let bloomReleaseTime: TimeInterval = 0.28
    public static let settlingDuration: TimeInterval = 1.10
    public static let steadyGlow: Double = 0.50
    public static let steadyPanelWhite: Double = 0.90
    public static func panelWhite(brightness: Double = 1, flare: Double = 0) -> Double {
        let power = min(1.6, max(0.1, brightness.isFinite ? brightness : 1))
        let steady = power <= 1 ? 0.32 + (steadyPanelWhite - 0.32) * sqrt(power)
                               : steadyPanelWhite + (power - 1) * 0.08
        // Leave SDR headroom for the same brief adaptation seen in the film.
        return steady + min(0.10, 1 - steady) * photoGlowMix(flare: flare, brightness: power)
    }

    public static func photoLevel(brightness: Double) -> Double {
        sqrt(min(1, max(0.1, brightness.isFinite ? brightness : 1)))
    }

    /// Continuous lamp power, independent of the switch-on clock.
    public static func photoBrightnessMix(brightness: Double) -> Double {
        let power = min(1.6, max(0.1, brightness.isFinite ? brightness : 1))
        return min(1, max(0, power - 1) / 0.6)
    }

    public static func photoGlowMix(flare: Double, brightness: Double) -> Double {
        let power = min(1.6, max(0.1, brightness.isFinite ? brightness : 1))
        return min(1, max(0, flare.isFinite ? flare : 0)) * sqrt(min(1, power))
    }

    /// Shared ignition exposure: brief overexposure, then exact steady brightness.
    public static func photoExposureStops(flare: Double, brightness: Double) -> Double {
        0.60 * photoGlowMix(flare: flare, brightness: brightness)
    }

    /// Time since OFF -> ON. Transmission rises first, then panel white,
    /// photographic exposure and edge light recover together without a dip.
    public static func sample(elapsed: TimeInterval, isLit: Bool,
                              reduceMotion: Bool = false) -> LightResponseSample {
        guard isLit else { return LightResponseSample(transmission: 0, flare: 0, glow: 0) }
        if reduceMotion || elapsed == .infinity || elapsed >= settlingDuration {
            return LightResponseSample(transmission: 1, flare: 0, glow: steadyGlow)
        }
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        let transmission = smoothstep(time / lampRiseDuration)
        let flare: Double
        if time <= peakTime {
            flare = smoothstep(time / peakTime)
        } else if time <= bloomReleaseTime {
            flare = 1
        } else {
            let progress = (time - bloomReleaseTime) / (settlingDuration - bloomReleaseTime)
            // Quintic easing starts and finishes with zero velocity and
            // acceleration: light first, then a gradual clearing, without a dip.
            flare = 1 - progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        }
        return LightResponseSample(transmission: transmission, flare: flare,
                                   glow: (steadyGlow + 0.22 * flare) * transmission)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
