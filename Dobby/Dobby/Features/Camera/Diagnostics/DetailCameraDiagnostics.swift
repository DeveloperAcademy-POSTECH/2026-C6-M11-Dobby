// Created by mason on 10/31/26.
import Foundation
import OSLog
import Darwin

/// Opt-in logging; the separate wide-camera experiment changes only device selection in the driver.
/// Profile builds can enable this through the scheme argument -CameraColorDiagnostics.
nonisolated final class DetailCameraDiagnostics: @unchecked Sendable {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-CameraColorDiagnostics") ||
        ProcessInfo.processInfo.environment["DOBBY_CAMERA_DIAGNOSTICS"] == "1"
    }
    static var wideCameraRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-CameraColorWideOnly")
    }
    let enabled: Bool
    let usesWideCamera: Bool
    let holdsWhiteBalanceOnInteraction: Bool
    let directory: URL
    private let writer = DispatchQueue(label: "com.dobby.camera.color-diagnostics", qos: .utility)
    private let lock = NSLock()
    private var captureCount = 0
    private var eventCount = 0
    private let logger = Logger(subsystem: "com.dobby.camera", category: "ColorDiagnostics")
    private let signposter = OSSignposter(subsystem: "com.dobby.camera", category: .pointsOfInterest)

    init(enabled: Bool = DetailCameraDiagnostics.requested, directory: URL? = nil,
         wideCameraOnly: Bool = DetailCameraDiagnostics.wideCameraRequested,
         holdWhiteBalance: Bool = ProcessInfo.processInfo.arguments.contains("-CameraColorHoldWB")) {
        self.enabled = enabled
        self.usesWideCamera = enabled && wideCameraOnly
        self.holdsWhiteBalanceOnInteraction = enabled && wideCameraOnly && holdWhiteBalance
        self.directory = directory ?? URL.applicationSupportDirectory
            .appending(path: "CameraDiagnostics", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        guard enabled else { return }
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        record("run_started", fields: ["hardware": machine,
            "cameraSelection": usesWideCamera ? "physicalWideOnly" : "automaticVirtualCamera",
            "whiteBalanceExperiment": holdsWhiteBalanceOnInteraction ? "holdOnInteraction" : "unchanged",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "captureLimit": 20, "sampleIntervalSeconds": 0.25,
            "note": "Device samples are read-time state, not guaranteed exposure-time metadata. Original means camera JPEG, not sensor RAW."])
        logger.notice("CameraColorDiagnostics enabled: \(self.directory.path, privacy: .public)")
        if usesWideCamera { logger.notice("CameraColorDiagnostics mode: physicalWideOnly (no 0.5x)") }
    }

    func beginCapture() -> UUID? {
        guard enabled else { return nil }
        let allowed = lock.withLock {
            guard captureCount < 20 else { return false }
            captureCount += 1
            return true
        }
        guard allowed else {
            logger.notice("CameraColorDiagnostics: 20 capture limit reached; restart app for another run.")
            return nil
        }
        let id = UUID()
        record("capture_begin", captureID: id)
        return id
    }

    func record(_ event: String, captureID: UUID? = nil, fields: [String: Any] = [:]) {
        guard enabled else { return }
        let sequence = lock.withLock { () -> Int? in
            guard eventCount < 10_000 else { return nil }
            eventCount += 1
            return eventCount
        }
        guard let sequence else { return }
        var entry = fields
        entry["event"] = event
        entry["sequence"] = sequence
        entry["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        entry["unixSeconds"] = Date().timeIntervalSince1970
        entry["captureID"] = captureID?.uuidString
        guard let encoded = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else {
            logger.error("CameraColorDiagnostics: invalid event payload")
            return
        }
        let message = String(decoding: encoded, as: UTF8.self)
        signposter.emitEvent("CameraColor", "\(message, privacy: .public)")
        writer.async { [self] in
            do {
                try prepareDirectory()
                let file = directory.appending(path: "events.jsonl")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try Data().write(to: file)
                }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: encoded + Data([0x0A]))
            } catch { logger.error("CameraColorDiagnostics event write failed: \(error.localizedDescription)") }
        }
    }

    enum Artifact: String { case original = "original.jpg", processed = "processed.jpg", metadata = "photo-metadata.plist" }

    func save(_ data: Data, as artifact: Artifact, captureID: UUID?) {
        guard enabled, let captureID else { return }
        writer.async { [self] in
            do {
                try prepareDirectory()
                let file = directory.appending(path: "\(captureID.uuidString)-\(artifact.rawValue)")
                try data.write(to: file, options: .atomic)
            } catch { logger.error("CameraColorDiagnostics artifact write failed: \(error.localizedDescription)") }
        }
    }

    /// Test barrier; production capture never waits for diagnostics disk writes.
    func flush() async {
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
}
