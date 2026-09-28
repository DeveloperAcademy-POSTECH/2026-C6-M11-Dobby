import Foundation
import XCTest
@testable import DobbyLiDARCore

@MainActor
final class MeasurementArchiveTests: XCTestCase {
    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DobbyArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(missingDepth: Bool = false) -> SavedMeasurement {
        let scene = SyntheticFixtures.scene(tilted: true, missingDepth: missingDepth)
        var options = MeasurementOptions()
        options.sampleRadius = 4
        options.minimumSamples = 8
        options.maximumDepthMeters = 2.6
        options.maximumPlaneResidualMeters = 0.007
        let result = LiDARMeasurementEngine(options: options).measure(
            frame: scene.frame, landmarks: scene.landmarks, definitions: [.testDistance]
        )
        return SavedMeasurement(
            id: UUID(), savedAt: Date(timeIntervalSince1970: 1_790_100_001),
            snapshot: .init(frame: scene.frame, imageJPEG: Data([0xff, 0xd8, 0xff, 0xd9])),
            landmarks: scene.landmarks, definitions: [.testDistance], result: result,
            referenceCentimeters: 50, options: options
        )
    }

    func testSaveLoadPreservesReplayInputsAndReference() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        let original = record()
        let file = try await archive.save(original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let restored = try await archive.load(original.id)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.savedAt, original.savedAt)
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.snapshot.imageJPEG, original.snapshot.imageJPEG)
        XCTAssertEqual(restored.snapshot.frame.sessionID, original.snapshot.frame.sessionID)
        XCTAssertEqual(restored.snapshot.frame.frameID, original.snapshot.frame.frameID)
        XCTAssertEqual(restored.snapshot.frame.timestamp, original.snapshot.frame.timestamp)
        XCTAssertEqual(restored.snapshot.frame.capturedAt, original.snapshot.frame.capturedAt)
        XCTAssertEqual(restored.snapshot.frame.imageSize, original.snapshot.frame.imageSize)
        XCTAssertEqual(restored.snapshot.frame.intrinsics, original.snapshot.frame.intrinsics)
        XCTAssertEqual(restored.snapshot.frame.depth.size, original.snapshot.frame.depth.size)
        XCTAssertEqual(restored.snapshot.frame.depth.values, original.snapshot.frame.depth.values)
        XCTAssertEqual(restored.snapshot.frame.depth.confidence, original.snapshot.frame.depth.confidence)
        XCTAssertEqual(restored.snapshot.frame.source, .synthetic)
        XCTAssertEqual(restored.landmarks.points.map(\.id), original.landmarks.points.map(\.id))
        XCTAssertEqual(restored.landmarks.points.map(\.point), original.landmarks.points.map(\.point))
        XCTAssertEqual(restored.landmarks.mask?.values, original.landmarks.mask?.values)
        XCTAssertEqual(restored.landmarks.origin, original.landmarks.origin)
        XCTAssertEqual(restored.options.sampleRadius, 4)
        XCTAssertEqual(restored.options.minimumSamples, 8)
        XCTAssertEqual(restored.options.maximumDepthMeters, 2.6)
        XCTAssertEqual(restored.options.maximumPlaneResidualMeters, 0.007)
        XCTAssertEqual(restored.referenceCentimeters, 50)
        XCTAssertEqual(restored.definitions.first?.landmarkIDs, ["A", "B"])

        let replay = LiDARMeasurementEngine(options: restored.options).measure(
            frame: restored.snapshot.frame, landmarks: restored.landmarks, definitions: restored.definitions
        )
        let value = try XCTUnwrap(replay.values.first)
        XCTAssertEqual(try XCTUnwrap(value.meters), 0.5, accuracy: 0.0005)
        XCTAssertEqual(value.meters, restored.result.values.first?.meters)
        XCTAssertEqual(value.status, restored.result.values.first?.status)
    }

    func testSummaryCarriesMeasurementMetadataAndSortsNewestFirst() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        let empty = try await archive.summaries()
        XCTAssertTrue(empty.isEmpty)
        let older = record()
        var newer = record()
        newer.savedAt = older.savedAt.addingTimeInterval(60)
        _ = try await archive.save(newer)
        _ = try await archive.save(older)
        // A write interrupted before summary creation must not look like a completed record.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        let summaries = try await archive.summaries()
        XCTAssertEqual(summaries.map(\.id), [newer.id, older.id])
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.savedAt, newer.savedAt)
        XCTAssertEqual(summary.source, .synthetic)
        XCTAssertEqual(summary.title, MeasurementDefinition.testDistance.title)
        XCTAssertEqual(try XCTUnwrap(summary.centimeters), 50, accuracy: 0.05)
        XCTAssertEqual(summary.status, .valid)
    }

    func testSameFrameSmoothedDepthSurvivesSaveWithoutReplacingPrimaryMeasurement() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        var original = record()
        original.snapshot.frame.source = .sceneDepth
        original.landmarks.origin = .manual
        var smoothed = original.snapshot.frame
        smoothed.source = .smoothedSceneDepth
        smoothed.depth.values = smoothed.depth.values.map { $0 * 1.2 }
        original.snapshot.smoothedFrame = smoothed
        original.snapshot.selectionSummary = .init(observedFrameCount: 12, eligibleCandidateCount: 9,
            waitingDurationSeconds: 0.4, selectionWindowSeconds: 0.35,
            selectedFrameTimestamp: smoothed.timestamp,
            selectedQuality: .init(timestamp: smoothed.timestamp, validDepthCoverage: 0.9,
                highConfidenceCoverage: 0.8, validDepthSampleCount: 100, trackingNormal: true,
                translationSpeedMetersPerSecond: 0.01, angularSpeedRadiansPerSecond: 0.02))
        _ = try await archive.save(original)
        let restored = try await archive.load(original.id)
        let companion = try XCTUnwrap(restored.snapshot.smoothedFrame)
        XCTAssertEqual(companion.frameID, restored.snapshot.frame.frameID)
        XCTAssertEqual(companion.sessionID, restored.snapshot.frame.sessionID)
        XCTAssertEqual(companion.timestamp, restored.snapshot.frame.timestamp)
        XCTAssertEqual(companion.capturedAt, restored.snapshot.frame.capturedAt)
        XCTAssertEqual(companion.intrinsics, restored.snapshot.frame.intrinsics)
        XCTAssertEqual(companion.source, .smoothedSceneDepth)
        XCTAssertEqual(companion.depth.values, smoothed.depth.values)
        XCTAssertEqual(companion.depth.confidence, smoothed.depth.confidence)
        XCTAssertEqual(restored.snapshot.selectionSummary, original.snapshot.selectionSummary)
        let replay = await MeasurementPipeline().measure(snapshot: restored.snapshot,
            landmarks: restored.landmarks, definitions: restored.definitions, options: restored.options)
        XCTAssertEqual(replay.source, .sceneDepth)
        XCTAssertEqual(try XCTUnwrap(replay.values.first?.meters), 0.5, accuracy: 0.0005)
    }

    func testLegacySnapshotWithoutComparisonOrSelectionFieldsStillImports() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = record()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var snapshot = try XCTUnwrap(json["snapshot"] as? [String: Any])
        snapshot.removeValue(forKey: "smoothedFrame")
        snapshot.removeValue(forKey: "selectionSummary")
        json["snapshot"] = snapshot
        json.removeValue(forKey: "referenceByDefinitionCentimeters")
        let url = folder.appendingPathComponent("legacy-v1.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let restored = try await MeasurementArchive(folder: folder).importRecord(from: url)
        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertNil(restored.snapshot.smoothedFrame)
        XCTAssertNil(restored.snapshot.selectionSummary)
        XCTAssertNil(restored.referenceByDefinitionCentimeters)
        XCTAssertEqual(restored.snapshot.frame.frameID, original.snapshot.frame.frameID)
        XCTAssertEqual(restored.result.values.first?.meters, original.result.values.first?.meters)
    }

    func testImportRejectsMalformedJSONAndEmptyFile() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = MeasurementArchive(folder: folder)
        let url = folder.appendingPathComponent("invalid.json")
        for bytes in [Data(), Data("{\"schemaVersion\":1, malformed".utf8)] {
            try bytes.write(to: url)
            do {
                _ = try await archive.importRecord(from: url)
                XCTFail("Malformed measurement file was accepted")
            } catch {
                XCTAssertTrue(error is ArchiveError || error is DecodingError)
            }
        }
    }

    func testImportRejectsUnsupportedSchemaAndPreservesSupportedFile() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = MeasurementArchive(folder: folder)
        let url = folder.appendingPathComponent("import.json")
        var candidate = record()
        try JSONEncoder().encode(candidate).write(to: url)
        let accepted = try await archive.importRecord(from: url)
        XCTAssertEqual(accepted.id, candidate.id)
        candidate.schemaVersion = 999
        try JSONEncoder().encode(candidate).write(to: url)
        do {
            _ = try await archive.importRecord(from: url)
            XCTFail("Future schema was interpreted as the current schema")
        } catch {
            XCTAssertTrue(error is ArchiveError)
        }
    }

    func testUnavailableDepthRoundTripKeepsNilDistanceAndFailureReason() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        let original = record(missingDepth: true)
        _ = try await archive.save(original)
        let restored = try await archive.load(original.id)
        let value = try XCTUnwrap(restored.result.values.first)
        XCTAssertNil(value.meters)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertEqual(value.failure, .insufficientDepth)
        XCTAssertTrue(restored.snapshot.frame.depth.values.allSatisfy { $0 == 0 })
        let summaries = try await archive.summaries()
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertNil(summary.centimeters)
        XCTAssertEqual(summary.status, .unavailable)
    }

    func testFailedSaveDoesNotEnterBaselineAndPreservesExistingDirectory() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        var candidate = record()
        candidate.snapshot.frame.source = .sceneDepth
        candidate.landmarks.origin = .manual
        let directory = folder.appendingPathComponent(candidate.id.uuidString)
        // Reproduce a destination at which writing the summary cannot succeed.
        let occupied = directory.appendingPathComponent("summary.json")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        do {
            _ = try await archive.save(candidate)
            XCTFail("Saving over an occupied destination should fail")
        } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
        let summaries = try await archive.summaries()
        let report = try await archive.baselineReport()
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertTrue(report.samples.isEmpty, "A failed save must not count as a completed baseline record")
    }

    func testInterruptedRecordWithoutSummaryIsExcludedFromBaseline() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var candidate = record()
        candidate.snapshot.frame.source = .sceneDepth
        candidate.landmarks.origin = .manual
        let directory = folder.appendingPathComponent(candidate.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("measurement.json"))
        let report = try await MeasurementArchive(folder: folder).baselineReport()
        XCTAssertEqual(report.samples.count, 0)
        XCTAssertEqual(report.malformedRecords, 1)
    }

    func testSavePublishesBothFilesAndDoesNotOverwriteExistingRecord() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        let original = record()
        _ = try await archive.save(original)
        var edited = original
        edited.referenceCentimeters = 99
        do {
            _ = try await archive.save(edited)
            XCTFail("Existing immutable record was overwritten")
        } catch { XCTAssertTrue(error is ArchiveError) }
        let restored = try await archive.load(original.id)
        XCTAssertEqual(restored.referenceCentimeters, original.referenceCentimeters)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [original.id.uuidString])
    }

    func testProviderFrameMismatchIsRejectedByPipeline() async throws {
        let original = record()
        var mismatched = original.landmarks
        mismatched.frameID = UUID()
        let pipeline = MeasurementPipeline()
        let result = try await pipeline.measure(
            snapshot: original.snapshot, provider: StubLandmarkProvider(output: mismatched),
            definitions: original.definitions
        )
        let value = try XCTUnwrap(result.values.first)
        XCTAssertNil(value.meters)
        XCTAssertEqual(value.failure, .frameMismatch)
        XCTAssertEqual(result.frameID, original.snapshot.frame.frameID)
    }

    func testPipelinePreservesProviderConfidenceAndSourceProvenance() async throws {
        let original = record()
        var modelPoints = original.landmarks
        modelPoints.origin = .model
        modelPoints.modelVersion = "fixture-model-1"
        modelPoints.points[0].confidence = 0.1
        let pipeline = MeasurementPipeline()
        let result = try await pipeline.measure(
            snapshot: original.snapshot, provider: StubLandmarkProvider(output: modelPoints),
            definitions: original.definitions
        )
        let value = try XCTUnwrap(result.values.first)
        // A provider's model output must not be relabelled as manual to bypass confidence checks.
        XCTAssertEqual(value.failure, .lowLandmarkConfidence)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertNil(value.meters)
        XCTAssertEqual(result.source, .synthetic)
    }
}

private struct StubLandmarkProvider: GarmentLandmarkProviding {
    let output: GarmentLandmarkSet
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet { output }
}
