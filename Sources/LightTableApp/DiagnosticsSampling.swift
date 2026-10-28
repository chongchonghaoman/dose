import AppKit
import Combine
import Foundation
import LightTableCore

@MainActor
final class DiagnosticsSampling: NSObject, ObservableObject {
    static let shared = DiagnosticsSampling()

    @Published private(set) var isRecording = false
    @Published private(set) var hasPendingReport = false

    private let fileURL: URL
    private var report: DiagnosticReport?
    private var startedAt: TimeInterval?
    private var timer: Timer?
    private var submittedFrameCount = 0
    private var completedFrameCount = 0
    private var frameDurationMicroseconds: Int64 = 0

    private override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OurLightTable", isDirectory: true)
        fileURL = root.appendingPathComponent("diagnostics-pending.json")
        super.init()
        recoverPendingReport()
        NotificationCenter.default.addObserver(self, selector: #selector(appActivated),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDeactivated),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    func start(loupeEnabled: Bool, edrEnabled: Bool) {
        guard !isRecording, !hasPendingReport else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        report = DiagnosticReport(sessionID: UUID().uuidString.lowercased(), appVersion: version,
            buildVersion: build, macOSMajor: os.majorVersion, macOSMinor: os.minorVersion,
            macOSPatch: os.patchVersion, architecture: architecture)
        startedAt = ProcessInfo.processInfo.systemUptime
        isRecording = true
        append(.samplingStarted)
        append(NSApp.isActive ? .appActivated : .appDeactivated)
        append(loupeEnabled ? .loupeEnabled : .loupeDisabled)
        append(edrEnabled ? .edrEnabled : .edrDisabled)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushSecond() }
        }
        persist()
    }

    func record(_ name: DiagnosticEventName, value1: Int64 = 0, value2: Int64 = 0, value3: Int64 = 0) {
        guard isRecording else { return }
        append(name, value1: value1, value2: value2, value3: value3)
    }

    func recordFrame(durationNanoseconds: UInt64) {
        guard isRecording else { return }
        completedFrameCount += 1
        frameDurationMicroseconds += Int64(min(durationNanoseconds / 1_000, UInt64(Int64.max)))
    }

    func recordFrameSubmitted(count: Int) {
        guard isRecording else { return }
        submittedFrameCount += count
    }

    func stopAndPrompt() {
        guard isRecording else {
            if hasPendingReport { promptUpload() }
            return
        }
        flushFrameSummary()
        timer?.invalidate(); timer = nil
        append(.samplingStopped)
        isRecording = false
        hasPendingReport = report != nil
        persist()
        promptUpload()
    }

    private func append(_ name: DiagnosticEventName, value1: Int64 = 0, value2: Int64 = 0, value3: Int64 = 0) {
        guard var current = report, let startedAt else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let milliseconds = UInt64(elapsed * 1_000)
        guard current.append(.init(elapsedMilliseconds: milliseconds, name: name,
                                   value1: value1, value2: value2, value3: value3)) else { return }
        report = current
    }

    private func flushSecond() {
        guard isRecording else { return }
        if let startedAt, ProcessInfo.processInfo.systemUptime - startedAt >= 900 {
            stopAndPrompt()
            return
        }
        flushFrameSummary()
        persist()
    }

    private func flushFrameSummary() {
        if submittedFrameCount > 0 || completedFrameCount > 0 {
            append(.frameSummary, value1: Int64(submittedFrameCount), value2: Int64(completedFrameCount),
                   value3: completedFrameCount == 0 ? 0 : frameDurationMicroseconds / Int64(completedFrameCount))
        }
        submittedFrameCount = 0
        completedFrameCount = 0
        frameDurationMicroseconds = 0
    }

    private func persist() {
        guard let report, let data = try? report.encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            hasPendingReport = true
        } catch { }
    }

    private func recoverPendingReport() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attributes[.modificationDate] as? Date else { return }
        guard Date().timeIntervalSince(modified) <= 7 * 24 * 60 * 60 else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(DiagnosticReport.self, from: data) else { return }
        report = decoded
        hasPendingReport = true
        DispatchQueue.main.async { [weak self] in self?.offerRecovery() }
    }

    private func offerRecovery() {
        guard hasPendingReport else { return }
        let alert = NSAlert()
        alert.messageText = "发现未完成的诊断采样"
        alert.informativeText = "上次观片台未正常退出，找到一份本地诊断记录。可现在查看并决定是否上传，也可删除记录。"
        alert.addButton(withTitle: "查看并上传…")
        alert.addButton(withTitle: "删除记录")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn: promptUpload()
        case .alertSecondButtonReturn: deletePending()
        default: break
        }
    }

    private func promptUpload() {
        guard let report, let data = try? report.encoded() else { return }
        let alert = NSAlert()
        alert.messageText = "上传诊断记录？"
        alert.informativeText = "将上传：诊断编号、观片台与 macOS 版本、芯片架构、应用和放大镜状态变化、EDR 开关状态，以及每秒汇总的 Metal 帧提交数、完成数和提交至完成耗时。不会上传照片、截图、路径、鼠标坐标、电脑名或 EDR 私有参数。单份不超过 5 MB；记录在阿里云私有存储保留 30 天。"
        alert.addButton(withTitle: "上传")
        alert.addButton(withTitle: "取消并删除")
        guard alert.runModal() == .alertFirstButtonReturn else { deletePending(); return }
        guard let endpoint = Bundle.main.infoDictionary?["LTDiagnosticsUploadURL"] as? String,
              let url = URL(string: endpoint), url.scheme == "https", url.host != nil else {
            showResult("上传地址尚未配置", detail: "本地诊断记录已保留；配置 HTTPS 接收地址并重新构建后即可重试。")
            return
        }
        Task { await upload(data, to: url, sessionID: report.sessionID) }
    }

    private func upload(_ data: Data, to url: URL, sessionID: String) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let body = try? JSONSerialization.jsonObject(with: responseData) as? [String: String],
                  let diagnosticID = body["diagnosticID"], diagnosticID == sessionID else {
                showResult("上传失败", detail: "诊断记录仍保留在本机，可稍后重试。")
                return
            }
            deletePending()
            showResult("诊断记录已上传", detail: "诊断编号：\(diagnosticID)")
        } catch {
            showResult("上传失败", detail: "网络请求未完成，诊断记录仍保留在本机，可稍后重试。")
        }
    }

    private func deletePending() {
        timer?.invalidate(); timer = nil
        report = nil; startedAt = nil
        isRecording = false; hasPendingReport = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func showResult(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func appActivated() { record(.appActivated) }
    @objc private func appDeactivated() { record(.appDeactivated) }
}
