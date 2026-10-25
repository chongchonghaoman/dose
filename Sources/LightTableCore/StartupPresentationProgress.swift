import Foundation

/// Presentation progress, never a readiness gate or an estimate of seconds left.
public enum StartupPresentationProgress {
    public static let photoStart = 0.5

    public static func preparation(completed: Int, total: Int, elapsed: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        let fraction = min(1, max(0, Double(completed) / Double(total)))
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        // A small arrival movement while the first image is being prepared.
        // Beyond this, actual work drives the bar; elapsed time cannot finish it.
        let arrival = 0.08 * (1 - exp(-time / 0.8))
        return min(0.98, max(arrival, fraction))
    }

    public static func photoCount(total: Int, progress: Double) -> Int? {
        guard total > 0, progress.isFinite, progress >= photoStart else { return nil }
        if progress >= 1 { return total }
        let fraction = (progress - photoStart) / (1 - photoStart)
        return max(1, min(total, Int((Double(total) * fraction).rounded(.down))))
    }
}
