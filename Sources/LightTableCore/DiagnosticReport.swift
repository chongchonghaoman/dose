import Foundation

public enum DiagnosticEventName: String, Codable, CaseIterable, Sendable {
    case samplingStarted = "sampling_started"
    case samplingStopped = "sampling_stopped"
    case appActivated = "app_activated"
    case appDeactivated = "app_deactivated"
    case loupeEnabled = "loupe_enabled"
    case loupeDisabled = "loupe_disabled"
    case loupeSceneAvailable = "loupe_scene_available"
    case loupeSceneUnavailable = "loupe_scene_unavailable"
    case pointerTrackingAvailable = "pointer_tracking_available"
    case pointerTrackingUnavailable = "pointer_tracking_unavailable"
    case loupePressed = "loupe_pressed"
    case loupeReleased = "loupe_released"
    case loupeCancelled = "loupe_cancelled"
    case edrEnabled = "edr_enabled"
    case edrDisabled = "edr_disabled"
    /// Schema 1 only: value1/value2 counted drawable surfaces, value3 repeated one buffer duration per surface.
    case frameSummary = "frame_summary"
    /// Schema 2, per second. value1 = command buffers committed, value2 = drawable surfaces encoded in them.
    case frameSubmitSummary = "frame_submit_summary"
    /// Schema 2, per second. value1 = command buffers completed, value2 = drawable surfaces in them,
    /// value3 = mean commit-to-completion microseconds per command buffer.
    case frameCompleteSummary = "frame_complete_summary"
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let elapsedMilliseconds: UInt64
    public let name: DiagnosticEventName
    public let value1: Int64
    public let value2: Int64
    public let value3: Int64

    public init(elapsedMilliseconds: UInt64, name: DiagnosticEventName,
                value1: Int64 = 0, value2: Int64 = 0, value3: Int64 = 0) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.name = name
        self.value1 = value1
        self.value2 = value2
        self.value3 = value3
    }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public static let maximumDurationMilliseconds: UInt64 = 15 * 60 * 1_000
    public static let maximumEncodedBytes = 5 * 1_024 * 1_024
    public static let maximumEvents = 20_000
    static let maximumEventEncodedBytes = 170

    public let schemaVersion: Int
    public let sessionID: String
    public let appVersion: String
    public let buildVersion: String
    public let macOSMajor: Int
    public let macOSMinor: Int
    public let macOSPatch: Int
    public let architecture: String
    public private(set) var truncated: Bool
    public private(set) var events: [DiagnosticEvent]

    public init(sessionID: String, appVersion: String, buildVersion: String,
                macOSMajor: Int, macOSMinor: Int, macOSPatch: Int, architecture: String) {
        schemaVersion = 2
        self.sessionID = sessionID
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.macOSMajor = macOSMajor
        self.macOSMinor = macOSMinor
        self.macOSPatch = macOSPatch
        self.architecture = architecture
        truncated = false
        events = []
    }

    @discardableResult
    public mutating func append(_ event: DiagnosticEvent,
                                maxBytes: Int = DiagnosticReport.maximumEncodedBytes) -> Bool {
        guard event.elapsedMilliseconds <= Self.maximumDurationMilliseconds,
              event.elapsedMilliseconds >= events.last?.elapsedMilliseconds ?? 0,
              maxBytes > 0 else { return false }

        events.append(event)
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
            truncated = true
        }
        // A worst-case bound lets the common path skip re-encoding the whole report per event.
        if metadataBytes() + events.count * Self.maximumEventEncodedBytes <= maxBytes { return true }
        while (try? encoded(maxBytes: maxBytes)) == nil, !events.isEmpty {
            events.removeFirst()
            truncated = true
        }
        return (try? encoded(maxBytes: maxBytes)) != nil
    }

    private func metadataBytes() -> Int {
        var empty = self
        empty.events = []
        return (try? JSONEncoder().encode(empty).count) ?? Int.max / 2
    }

    public func encoded(maxBytes: Int = DiagnosticReport.maximumEncodedBytes) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= maxBytes else { throw DiagnosticReportError.exceedsByteLimit }
        return data
    }
}

/// Records a state only when it differs from the previous one, so per-frame
/// updates that keep the same state never become diagnostic events.
public struct DiagnosticEdgeTracker: Sendable {
    private var last: Bool
    public init(initial: Bool = false) { last = initial }
    public mutating func changed(to state: Bool) -> Bool {
        guard state != last else { return false }
        last = state
        return true
    }
}

public enum DiagnosticReportError: Error, Equatable {
    case exceedsByteLimit
}
