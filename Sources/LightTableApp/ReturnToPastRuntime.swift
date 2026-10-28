import Foundation
import CryptoKit
import Darwin

/// Shared by the local worker and the embedded, offline viewer.
enum ReturnToPastResources {
    static var directory: URL {
        // Bundle.module traps when a standalone App contains flattened resources
        // instead of SwiftPM's resource bundle. Probe paths without initializing it.
        let main = Bundle.main
        var roots = [main.resourceURL].compactMap { $0 }
        if let executable = main.executableURL {
            let bundle = executable.deletingLastPathComponent()
                .appendingPathComponent("LightTable_LightTableApp.bundle", isDirectory: true)
            roots += [bundle.appendingPathComponent("Contents/Resources", isDirectory: true), bundle]
        }
        let candidates = roots.map { $0.appendingPathComponent("ReturnToPast", isDirectory: true) }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("sharp_worker.py").path) }
            ?? candidates.first ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ReturnToPast")
    }
}

enum ReturnToPastRuntime {
    typealias Progress = @Sendable (String, Double?) -> Void
    private static let checkpointHash = "94211a75198c47f61fca7d739ba08a215418d8d398d48fddf023baccc24f073d"
    private static let uvHash = "c729adb365114e844dd7f9316313a7ed6443b89bb5681d409eebac78b0bd06c8"
    private static let revision = "uv0.11.8-python3.13.13-torch2.8.0-sharp-aed6527-v1"

    /// Returns scene.json; scene.ply is written beside it only after successful inference.
    static func generate(input: URL, output: URL, lowMemory: Bool,
                         progress: @escaping Progress) async throws -> URL {
        let work = Task.detached(priority: .utility) {
            let cancellation = RuntimeCancellation()
            return try await withTaskCancellationHandler {
                let resources = ReturnToPastResources.directory
                guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("sharp_worker.py").path) else {
                    throw RuntimeFailure("回到过去的运行资源缺失，请重新安装应用。")
                }
                let environment = ProcessInfo.processInfo.environment
                let runtime = try runtimeDirectory()
                let python: URL
                let checkpoint: URL
                let firstInference: Bool
                // Explicit developer overrides are never inferred from machine-specific locations.
                if let customPython = environment["LIGHTTABLE_SHARP_PYTHON"],
                   let customCheckpoint = environment["LIGHTTABLE_SHARP_CHECKPOINT"] {
                    python = URL(fileURLWithPath: customPython)
                    checkpoint = URL(fileURLWithPath: customCheckpoint)
                    firstInference = false
                    guard FileManager.default.isExecutableFile(atPath: python.path),
                          FileManager.default.fileExists(atPath: checkpoint.path) else {
                        throw RuntimeFailure("开发环境指定的 Python 或 SHARP 模型不存在。")
                    }
                } else {
                    (python, checkpoint, firstInference) = try await prepare(runtime: runtime, resources: resources,
                                                                              cancellation: cancellation, progress: progress)
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let cache = runtime.appendingPathComponent("matplotlib", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                var arguments = ["-u", resources.appendingPathComponent("sharp_worker.py").path,
                                 "--input", input.path, "--output", output.path, "--checkpoint", checkpoint.path]
                if lowMemory { arguments.append("--low-memory") }
                let inferencePrefix = firstInference ? "首次安装成功，正在进行首次推理\n" : ""
                progress(inferencePrefix + (lowMemory ? "正在本机生成，低内存模式会慢一些" : "正在本机生成"), 0.05)
                try await command(python, arguments, environment: [
                    "PYTHONPATH": resources.appendingPathComponent("sharp-source").path,
                    "MPLCONFIGDIR": cache.path, "MPLBACKEND": "Agg",
                    "PYTHONUNBUFFERED": "1", "HF_HUB_OFFLINE": "1",
                    "PYTORCH_ENABLE_MPS_FALLBACK": "1"
                ], cancellation: cancellation) { line in
                    guard let data = line.data(using: .utf8),
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let stage = value["stage"] as? String else { return }
                    let fraction: Double? = {
                        guard let completed = value["completed"] as? Double,
                              let total = value["total"] as? Double, total > 0 else { return nil }
                        return completed / total
                    }()
                    switch stage {
                    case "loading": progress(inferencePrefix + "正在载入 SHARP 模型", 0.08)
                    case "predicting", "depth": progress(inferencePrefix + "正在估计照片深度", nil)
                    case "encoding": progress(inferencePrefix + "正在分析照片分块", nil)
                    case "features": progress(inferencePrefix + "正在构建空间特征", nil)
                    case "gaussians": progress(inferencePrefix + "正在计算高斯粒子", nil)
                    case "composing": progress(inferencePrefix + "正在合成高斯场景", nil)
                    case "projecting": progress(inferencePrefix + "正在整理高斯粒子", 0.85 + 0.10 * (fraction ?? 0))
                    case "saving": progress(inferencePrefix + "正在准备播放", 0.97)
                    case "error": progress(value["message"] as? String ?? "生成失败", nil)
                    default: break
                    }
                }
                try Task.checkCancellation()
                let scene = output.appendingPathComponent("scene.json")
                guard FileManager.default.fileExists(atPath: scene.path),
                      FileManager.default.fileExists(atPath: output.appendingPathComponent("scene.ply").path) else {
                    throw RuntimeFailure("SHARP 未生成完整场景，请重试。")
                }
                progress("生成完成", 1)
                return scene
            } onCancel: { cancellation.cancel() }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func runtimeDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let runtime = base.appendingPathComponent("OurLightTable/ReturnToPast/runtime-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        return runtime
    }

    private static func prepare(runtime: URL, resources: URL, cancellation: RuntimeCancellation,
                                progress: @escaping Progress) async throws -> (URL, URL, Bool) {
        #if !arch(arm64)
        throw RuntimeFailure("当前 SHARP 本机生成环境需要 Apple 芯片 Mac。")
        #else
        let lockPath = runtime.appendingPathComponent("install.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw RuntimeFailure("无法创建回到过去的运行目录。") }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        while flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw RuntimeFailure("无法锁定回到过去的运行环境，请重试。")
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let python = runtime.appendingPathComponent("venv/bin/python")
        let checkpoint = runtime.appendingPathComponent("sharp_2572gikvuh.pt")
        let marker = runtime.appendingPathComponent("ready.json")
        if let data = try? Data(contentsOf: marker),
           let ready = try? JSONDecoder().decode(RuntimeReady.self, from: data),
           ready.revision == revision, ready.checkpointHash == checkpointHash,
           FileManager.default.isExecutableFile(atPath: python.path),
           fileSize(checkpoint) == ready.checkpointBytes {
            return (python, checkpoint, false)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: configuration)
        cancellation.register(session: session)
        defer { session.invalidateAndCancel(); cancellation.clearSession() }
        let uv = runtime.appendingPathComponent("uv/uv")
        if !FileManager.default.isExecutableFile(atPath: uv.path) {
            let archive = runtime.appendingPathComponent("uv-\(UUID().uuidString).tar.gz")
            defer { try? FileManager.default.removeItem(at: archive) }
            progress("首次使用：正在下载运行工具", nil)
            try await download(URL(string: "https://github.com/astral-sh/uv/releases/download/0.11.8/uv-aarch64-apple-darwin.tar.gz")!,
                               to: archive, expectedHash: uvHash, session: session, progress: progress,
                               label: "首次使用：下载运行工具")
            let staging = runtime.appendingPathComponent("uv-install-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            try await command(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path,
                              "--strip-components", "1"], cancellation: cancellation)
            let destination = uv.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: staging.appendingPathComponent("uv"), to: uv)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        }
        let installEnvironment = [
            "UV_PYTHON_INSTALL_DIR": runtime.appendingPathComponent("python").path,
            "UV_CACHE_DIR": runtime.appendingPathComponent("uv-cache").path,
            "UV_PYTHON_DOWNLOADS": "automatic", "UV_NO_PROGRESS": "1", "UV_NO_CONFIG": "1"
        ]
        progress("首次使用：正在准备 Python 3.13", nil)
        try await command(uv, ["python", "install", "--no-bin", "3.13.13"], environment: installEnvironment,
                          cancellation: cancellation)
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            try await command(uv, ["venv", "--python", "3.13.13", "--managed-python", python.deletingLastPathComponent().deletingLastPathComponent().path],
                              environment: installEnvironment, cancellation: cancellation)
        }
        progress("首次使用：正在安装生成依赖，完成后可重复使用", nil)
        try await command(uv, ["pip", "install", "--python", python.path, "--only-binary", ":all:",
                              "--requirement", resources.appendingPathComponent("requirements.txt").path],
                          environment: installEnvironment, cancellation: cancellation)
        try await command(python, ["-c", "import torch, torchvision, timm; from sharp.models import create_predictor; from sharp.utils import io; from sharp.utils.gaussians import save_ply; assert torch.__version__.split('+')[0] == '2.8.0'; assert torchvision.__version__.split('+')[0] == '0.23.0'; assert timm.__version__ == '1.0.20'"],
                          environment: ["PYTHONPATH": resources.appendingPathComponent("sharp-source").path,
                                        "MPLBACKEND": "Agg", "MPLCONFIGDIR": runtime.appendingPathComponent("matplotlib").path],
                          cancellation: cancellation)
        if try !validCheckpoint(checkpoint) {
            try reuseCachedCheckpoint(to: checkpoint, progress: progress)
        }
        if try !validCheckpoint(checkpoint) {
            progress("首次使用：正在下载 SHARP 模型（约 2.6 GB）", nil)
            try await download(URL(string: "https://ml-site.cdn-apple.com/models/sharp/sharp_2572gikvuh.pt")!,
                               to: checkpoint, expectedHash: checkpointHash, session: session,
                               progress: progress, label: "首次使用：下载 SHARP 模型")
        }
        try Task.checkCancellation()
        let ready = RuntimeReady(revision: revision, checkpointHash: checkpointHash, checkpointBytes: fileSize(checkpoint))
        try JSONEncoder().encode(ready).write(to: marker, options: .atomic)
        return (python, checkpoint, true)
        #endif
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func cachedCheckpoints(environment: [String: String] = ProcessInfo.processInfo.environment,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots: [URL] = []
        if let torchHome = environment["TORCH_HOME"], !torchHome.isEmpty {
            roots.append(URL(fileURLWithPath: torchHome, isDirectory: true))
        }
        if let cacheHome = environment["XDG_CACHE_HOME"], !cacheHome.isEmpty {
            roots.append(URL(fileURLWithPath: cacheHome, isDirectory: true).appendingPathComponent("torch"))
        }
        roots.append(home.appendingPathComponent(".cache/torch", isDirectory: true))
        return roots.map { $0.appendingPathComponent("hub/checkpoints/sharp_2572gikvuh.pt") }
    }

    private static func reuseCachedCheckpoint(to destination: URL, progress: Progress) throws {
        for candidate in cachedCheckpoints() {
            guard candidate.standardizedFileURL != destination.standardizedFileURL,
                  FileManager.default.fileExists(atPath: candidate.path) else { continue }
            progress("正在校验本机已有的 SHARP 模型", nil)
            do {
                guard try validCheckpoint(candidate) else { continue }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            try Task.checkCancellation()
            progress("正在复用本机已有的 SHARP 模型，无需下载", nil)
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent("checkpoint-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: candidate, to: staging)
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            return
        }
    }

    private static func validCheckpoint(_ url: URL) throws -> Bool {
        guard fileSize(url) > 2_000_000_000 else { return false }
        return try sha256(url) == checkpointHash
    }

    private static func sha256(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func download(_ url: URL, to destination: URL, expectedHash: String,
                                 session: URLSession, progress: @escaping Progress, label: String) async throws {
        let delegate = RuntimeDownloadProgress(label: label, progress: progress)
        progress("\(label)：正在连接下载服务器", nil)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.start(url: url, configuration: session.configuration, continuation: continuation)
                }
            } onCancel: { delegate.cancel() }
        } catch let error as URLError where error.code == .timedOut {
            throw RuntimeFailure("下载长时间没有响应，请检查网络后重试。本机已有模型会优先复用。")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw RuntimeFailure("下载失败，请检查网络后重试。")
        }
        progress("\(label)：正在校验", nil)
        guard try sha256(temporary) == expectedHash else {
            throw RuntimeFailure("下载文件校验失败，请检查网络后重试。")
        }
        try Task.checkCancellation()
        let staging = destination.deletingLastPathComponent().appendingPathComponent("download-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: temporary, to: staging)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private static func command(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                                cancellation: RuntimeCancellation,
                                line: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try cancellation.check()
                    let pipe = Pipe()
                    let readFD = pipe.fileHandleForReading.fileDescriptor
                    let writeFD = pipe.fileHandleForWriting.fileDescriptor
                    var actions: posix_spawn_file_actions_t?
                    var attributes: posix_spawnattr_t?
                    posix_spawn_file_actions_init(&actions)
                    posix_spawnattr_init(&attributes)
                    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                    posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
                    posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
                    posix_spawn_file_actions_addclose(&actions, readFD)
                    posix_spawn_file_actions_addclose(&actions, writeFD)
                    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
                    posix_spawnattr_setpgroup(&attributes, 0)
                    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
                    var childEnvironment = ProcessInfo.processInfo.environment
                    childEnvironment.merge(environment) { _, value in value }
                    // GUI launches often omit the ordinary system tool search path.
                    childEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
                    let envp = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
                    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
                    var pid: pid_t = 0
                    let result = argv.withUnsafeBufferPointer { args in
                        envp.withUnsafeBufferPointer { vars in
                            posix_spawn(&pid, executable.path, &actions, &attributes,
                                        UnsafeMutablePointer(mutating: args.baseAddress!),
                                        UnsafeMutablePointer(mutating: vars.baseAddress!))
                        }
                    }
                    try? pipe.fileHandleForWriting.close()
                    guard result == 0 else { throw RuntimeFailure("无法启动本机生成环境：\(String(cString: strerror(result)))") }
                    cancellation.register(pid: pid)
                    var pending = Data()
                    var diagnostic = ""
                    while true {
                        let data = pipe.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        pending.append(data)
                        while let newline = pending.firstIndex(of: 10) {
                            let value = String(decoding: pending[..<newline], as: UTF8.self)
                            pending.removeSubrange(...newline)
                            line(value)
                            diagnostic = String((diagnostic + value + "\n").suffix(16_384))
                        }
                    }
                    if !pending.isEmpty {
                        let value = String(decoding: pending, as: UTF8.self)
                        line(value); diagnostic = String((diagnostic + value).suffix(16_384))
                    }
                    try? pipe.fileHandleForReading.close()
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    cancellation.clear(pid: pid)
                    try cancellation.check()
                    guard status == 0 else {
                        let message = diagnostic.split(separator: "\n").reversed().compactMap { value -> String? in
                            guard let data = value.data(using: .utf8),
                                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  object["stage"] as? String == "error" else { return nil }
                            return object["message"] as? String
                        }.first
                        throw RuntimeFailure(message ?? "本机生成环境运行失败。\n\(diagnostic.suffix(1500))")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private struct RuntimeReady: Codable {
    let revision: String
    let checkpointHash: String
    let checkpointBytes: UInt64
}

private struct RuntimeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class RuntimeDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let label: String
    let progress: ReturnToPastRuntime.Progress
    private var lastUpdate = Date.distantPast
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var result: Result<(URL, URLResponse), Error>?

    init(label: String, progress: @escaping ReturnToPastRuntime.Progress) {
        self.label = label; self.progress = progress
    }

    func start(url: URL, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        // Explicit tasks preserve byte callbacks; async download conveniences suppress them.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock(); cancelled = true; let active = task; lock.unlock()
        active?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession deletes location when this callback returns, before the await resumes.
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("lighttable-download-\(UUID().uuidString)")
        let outcome: Result<(URL, URLResponse), Error>
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: location, to: saved)
            outcome = .success((saved, response))
        } catch { outcome = .failure(error) }
        lock.lock(); result = outcome; lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        self.task = nil
        let downloaded = result
        result = nil
        let failure: Error? = cancelled ? CancellationError() : error
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let failure {
            if case let .success((temporary, _)) = downloaded { try? FileManager.default.removeItem(at: temporary) }
            pending?.resume(throwing: failure)
        } else {
            pending?.resume(with: downloaded ?? .failure(URLError(.unknown)))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard Date().timeIntervalSince(lastUpdate) > 0.2 else { return }
        lastUpdate = Date()
        let received = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
        if totalBytesExpectedToWrite > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytesExpectedToWrite, countStyle: .file)
            progress("\(label)：\(received) / \(total)", Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            progress("\(label)：已下载 \(received)", nil)
        }
    }
}

private final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pid: pid_t?
    private var session: URLSession?
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func register(session: URLSession) {
        lock.lock(); self.session = session; let value = cancelled; lock.unlock()
        if value { session.invalidateAndCancel() }
    }
    func clearSession() { lock.lock(); session = nil; lock.unlock() }
    func register(pid: pid_t) {
        lock.lock(); self.pid = pid; let value = cancelled; lock.unlock()
        if value { terminate(pid) }
    }
    func clear(pid: pid_t) { lock.lock(); if self.pid == pid { self.pid = nil }; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let process = pid; let network = session; lock.unlock()
        network?.invalidateAndCancel()
        if let process { terminate(process) }
    }
    private func terminate(_ process: pid_t) {
        kill(-process, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); let stillRunning = pid == process; lock.unlock()
            if stillRunning { kill(-process, SIGKILL) }
        }
    }
}
