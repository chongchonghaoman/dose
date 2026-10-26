import Foundation
import CoreGraphics
import Observation

struct ReturnToPastScene: Decodable, Sendable {
    let width: Int
    let height: Int
    let focal: Double
    let depth: Double
}

/// One temporary scene at a time. Generation always starts from the source URL,
/// independently of the table's thumbnail and transmitted-light caches.
@MainActor @Observable
final class ReturnToPastSession {
    static let shared = ReturnToPastSession()
    enum Phase { case idle, preparing, generating, revealing, playing, failed }

    private(set) var slideID: UUID?
    private(set) var sourceURL: URL?
    private(set) var runID = UUID()
    private(set) var phase = Phase.idle
    private(set) var status = ""
    private(set) var progress: Double?
    private(set) var aperture = CGRect(x: 0, y: 0, width: 1, height: 1)
    private(set) var scene: ReturnToPastScene?
    private(set) var directory: URL?
    private(set) var hasRevealed = false
    private(set) var resetID = 0
    @ObservationIgnored private var generation: Task<Void, Never>?
    @ObservationIgnored private var retiringGeneration: Task<Void, Never>?

    var isActive: Bool { slideID != nil }
    var canPlay: Bool { scene != nil && (phase == .revealing || phase == .playing) }

    func start(slideID: UUID, source: URL, aperture initialAperture: CGRect) {
        let previousGeneration = generation ?? retiringGeneration
        close()
        let run = UUID()
        let job = FileManager.default.temporaryDirectory
            .appendingPathComponent("OurLightTable-ReturnToPast", isDirectory: true)
            .appendingPathComponent(run.uuidString, isDirectory: true)
        runID = run
        self.slideID = slideID; sourceURL = source; directory = job
        aperture = initialAperture
        phase = .preparing; status = "正在读取原始照片"; progress = 0
        generation = Task { [weak self] in
            // A rapid switch waits for the cancelled process to exit before
            // another worker may allocate its model.
            if let previousGeneration { await previousGeneration.value }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: job); return
            }
            if let self, self.runID == run { self.retiringGeneration = nil }
            let preparedTask = Task.detached(priority: .utility) {
                try ReturnToPastImage.prepare(source: source, directory: job)
            }
            do {
                let prepared = try await withTaskCancellationHandler {
                    try await preparedTask.value
                } onCancel: { preparedTask.cancel() }
                try Task.checkCancellation()
                guard let self, self.runID == run else {
                    try? FileManager.default.removeItem(at: job); return
                }
                self.aperture = prepared.aperture
                self.phase = .generating
                // Every Mac may attempt generation. Small-memory machines use
                // the serial CPU path instead of allocating an MPS workspace.
                let lowMemory = ProcessInfo.processInfo.physicalMemory < 24 * 1_024 * 1_024 * 1_024
                let manifest = try await ReturnToPastRuntime.generate(input: prepared.inputURL,
                    output: job, lowMemory: lowMemory) { [weak self] label, fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.runID == run, self.phase == .generating else { return }
                        let sameStage = self.status == label
                        self.status = label
                        if let fraction {
                            self.progress = max(sameStage ? self.progress ?? 0 : 0, min(1, max(0, fraction)))
                        } else {
                            self.progress = nil
                        }
                    }
                }
                try Task.checkCancellation()
                guard self.runID == run else {
                    try? FileManager.default.removeItem(at: job); return
                }
                let scene = try JSONDecoder().decode(ReturnToPastScene.self, from: Data(contentsOf: manifest))
                guard scene.width > 0, scene.height > 0, scene.focal.isFinite, scene.focal > 0,
                      scene.depth.isFinite, scene.depth > 0 else { throw SceneError() }
                self.scene = scene
                self.phase = .revealing; self.status = "正在唤回这一刻"; self.progress = 1
                self.generation = nil
            } catch {
                // Runtime returns only after its child process has stopped, so
                // removing the directory cannot race a late scene.ply write.
                try? FileManager.default.removeItem(at: job)
                guard let self, self.runID == run else { return }
                self.generation = nil
                if Task.isCancelled || error is CancellationError { self.close(); return }
                self.phase = .failed; self.status = error.localizedDescription; self.progress = nil
            }
        }
    }

    func revealed(run: UUID) {
        guard runID == run, canPlay else { return }
        hasRevealed = true; phase = .playing; status = ""
    }

    func viewerFailed(_ message: String, run: UUID) {
        guard runID == run, canPlay else { return }
        phase = .failed; status = message
    }

    func retry() {
        guard let slideID, let sourceURL else { return }
        start(slideID: slideID, source: sourceURL, aperture: aperture)
    }

    func resetView() { resetID += 1 }

    func close() {
        let previous = directory
        let running = generation
        runID = UUID()
        // Keep the cancellation barrier when close and start are separate
        // actions, until the old worker has actually released its model.
        if let running { retiringGeneration = running }
        generation = nil; running?.cancel()
        slideID = nil; sourceURL = nil; scene = nil; directory = nil
        phase = .idle; status = ""; progress = nil; hasRevealed = false
        // A running task owns cleanup after cancellation has reached the worker.
        if running == nil, let previous { try? FileManager.default.removeItem(at: previous) }
    }

    private struct SceneError: LocalizedError {
        var errorDescription: String? { "生成的场景信息不完整，请重试。" }
    }
}
