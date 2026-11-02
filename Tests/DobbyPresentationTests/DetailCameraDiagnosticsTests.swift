// Created by mason on 10/31/26.
import Foundation
import XCTest
@testable import Dobby

@MainActor
final class DetailCameraDiagnosticsTests: XCTestCase {
    func testDisabledDiagnosticsDoesNotWriteOrAllocateCaptureID() async throws {
        let root = temporaryDirectory()
        let diagnostics = DetailCameraDiagnostics(enabled: false, directory: root, wideCameraOnly: true)
        XCTAssertFalse(diagnostics.usesWideCamera, "광각 옵션만으로 일반 촬영을 변경하지 않는다")
        XCTAssertNil(diagnostics.beginCapture())
        diagnostics.record("ignored")
        diagnostics.save(Data([1]), as: .original, captureID: UUID())
        await diagnostics.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRunRecordDistinguishesWideExperimentFromAutomaticCamera() async throws {
        for wideOnly in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let diagnostics = DetailCameraDiagnostics(enabled: true, directory: root, wideCameraOnly: wideOnly)
            XCTAssertEqual(diagnostics.usesWideCamera, wideOnly)
            await diagnostics.flush()
            let data = try Data(contentsOf: root.appending(path: "events.jsonl"))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(event["cameraSelection"] as? String,
                           wideOnly ? "physicalWideOnly" : "automaticVirtualCamera")
        }
    }

    func testInteractionHoldRequiresAllThreeOptions() async throws {
        for enabled in [false, true] {
            for wide in [false, true] {
                for hold in [false, true] {
                    let root = temporaryDirectory()
                    defer { try? FileManager.default.removeItem(at: root) }
                    let diagnostics = DetailCameraDiagnostics(enabled: enabled, directory: root,
                        wideCameraOnly: wide, holdWhiteBalance: hold)
                    XCTAssertEqual(diagnostics.holdsWhiteBalanceOnInteraction, enabled && wide && hold)
                    await diagnostics.flush()
                    if enabled {
                        let data = try Data(contentsOf: root.appending(path: "events.jsonl"))
                        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        XCTAssertEqual(event["whiteBalanceExperiment"] as? String,
                            wide && hold ? "holdOnInteraction" : "unchanged")
                    } else {
                        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
                    }
                }
            }
        }
    }

    func testPairedBytesAndEventsKeepOneCaptureIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DetailCameraDiagnostics(enabled: true, directory: root)
        let id = try XCTUnwrap(diagnostics.beginCapture())
        let original = Data([0xFF, 0xD8, 1, 2, 3]), processed = Data([0xFF, 0xD8, 4, 5])
        diagnostics.save(original, as: .original, captureID: id)
        diagnostics.record("processing_begin", captureID: id, fields: ["zoomDisplay": 2.0])
        diagnostics.save(processed, as: .processed, captureID: id)
        diagnostics.record("photo_saved", captureID: id, fields: ["assetID": "test-asset"])
        await diagnostics.flush()
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "\(id)-original.jpg")), original)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "\(id)-processed.jpg")), processed)
        let events = try String(contentsOf: root.appending(path: "events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(events.compactMap { $0["event"] as? String },
                       ["run_started", "capture_begin", "processing_begin", "photo_saved"])
        XCTAssertEqual(events.dropFirst().compactMap { $0["captureID"] as? String }, Array(repeating: id.uuidString, count: 3))
        XCTAssertEqual(events.last?["assetID"] as? String, "test-asset")
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testDiagnosticCaptureLimitDoesNotAllocateMoreThanTwentyPairs() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = DetailCameraDiagnostics(enabled: true, directory: root)
        let ids = (0..<20).compactMap { _ in diagnostics.beginCapture() }
        XCTAssertEqual(Set(ids).count, 20)
        XCTAssertNil(diagnostics.beginCapture())
        diagnostics.save(Data([1]), as: .processed, captureID: nil)
        await diagnostics.flush()
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted(), ["events.jsonl"])
    }

    func testDiagnosticDiskFailureDoesNotBlockCompletion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let diagnostics = DetailCameraDiagnostics(enabled: true, directory: root)
        let id = try XCTUnwrap(diagnostics.beginCapture())
        diagnostics.save(Data([2]), as: .original, captureID: id)
        await diagnostics.flush()
        XCTAssertEqual(try Data(contentsOf: root), Data([1]))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "camera-diagnostics-\(UUID())")
    }
}
