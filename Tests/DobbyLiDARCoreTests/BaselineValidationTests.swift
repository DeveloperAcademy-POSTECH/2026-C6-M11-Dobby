import Foundation
import XCTest
@testable import DobbyLiDARCore

@MainActor
final class BaselineValidationTests: XCTestCase {
    /// This is a fabricated fixture exercising provenance rules, not physical sensor evidence.
    private func fixture(source: DepthSource = .sceneDepth, origin: LandmarkOrigin = .manual,
                         missing: Bool = false, reference: Double? = 50, tilted: Bool = false) -> SavedMeasurement {
        var scene = SyntheticFixtures.scene(tilted: tilted, missingDepth: missing)
        scene.frame.frameID = UUID()
        scene.landmarks.frameID = scene.frame.frameID
        scene.frame.source = source
        scene.landmarks.origin = origin
        let result = LiDARMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks, definitions: [.testDistance])
        return .init(id: UUID(), savedAt: .now, snapshot: .init(frame: scene.frame, imageJPEG: Data()),
                     landmarks: scene.landmarks, definitions: [.testDistance], result: result,
                     referenceCentimeters: reference, options: .init(),
                     testContext: .init(category: .bottoms, specimenName: "fixture only", deviceModel: "test device", conditions: "tilted"))
    }

    private func pairedFixture(reference: Double? = 50, smoothedScale: Float = 1) -> SavedMeasurement {
        var record = fixture(reference: reference, tilted: true)
        var companion = record.snapshot.frame
        companion.source = .smoothedSceneDepth
        companion.depth.values = companion.depth.values.map { $0 * smoothedScale }
        record.snapshot.smoothedFrame = companion
        return record
    }

    func testEmptyReportDoesNotInventAccuracy() {
        let report = BaselineReportBuilder().report()
        XCTAssertNil(report.stabilized.meanAbsoluteErrorCentimeters)
        XCTAssertNil(report.stabilized.numericResultRate)
        XCTAssertEqual(report.stabilized.attempts, 0)
        XCTAssertEqual(report.pairedRaw.attempts, 0)
        XCTAssertEqual(report.pairedSmoothed.attempts, 0)
        XCTAssertNil(report.pairedRaw.meanAbsoluteErrorCentimeters)
        XCTAssertNil(report.pairedSmoothed.meanAbsoluteErrorCentimeters)
    }

    func testSyntheticAndModelLandmarksAreExcludedFromManualSensorBaseline() {
        var builder = BaselineReportBuilder()
        builder.add(fixture(source: .synthetic))
        builder.add(fixture(origin: .model))
        builder.add(fixture(origin: .synthetic))
        builder.add(fixture())
        let report = builder.report()
        XCTAssertEqual(report.samples.count, 1)
        XCTAssertEqual(report.syntheticRecords, 1)
        XCTAssertEqual(report.nonManualRecords, 2)
    }

    func testRepeatedSaveUsesNewestEditWithoutInflatingIndependentTrials() throws {
        var builder = BaselineReportBuilder()
        let original = fixture()
        var edited = original
        edited.id = UUID()
        edited.savedAt = original.savedAt.addingTimeInterval(1)
        edited.referenceCentimeters = 48
        builder.add(edited)
        builder.add(original)
        let report = builder.report()
        XCTAssertEqual(report.samples.count, 1)
        XCTAssertEqual(report.duplicateSaves, 1)
        XCTAssertEqual(report.samples.first?.recordID, edited.id)
        XCTAssertEqual(try XCTUnwrap(report.stabilized.meanAbsoluteErrorCentimeters), 2, accuracy: 0.05)
    }

    func testFailuresAndMissingReferencesRemainVisibleInDenominators() throws {
        var builder = BaselineReportBuilder()
        builder.add(fixture())
        builder.add(fixture(missing: true))
        builder.add(fixture(reference: nil))
        let report = builder.report()
        XCTAssertEqual(report.stabilized.attempts, 3)
        XCTAssertEqual(report.stabilized.referencedAttempts, 2)
        XCTAssertEqual(report.stabilized.compared, 1)
        XCTAssertEqual(report.stabilized.unavailable, 1)
        XCTAssertEqual(report.stabilized.numericResults, 2)
        XCTAssertEqual(try XCTUnwrap(report.stabilized.numericResultRate), 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(report.baseline.uncertain, 2)
        XCTAssertEqual(report.baseline.compared, 1)
    }

    func testReplayUsesCurrentEngineAndChangesOnlyPlaneOption() throws {
        var record = fixture(tilted: true)
        record.result.values[0].meters = 999 // A saved result is not trusted as a fresh replay.
        record.options.sampleRadius = 4
        record.options.minimumSamples = 8
        var builder = BaselineReportBuilder()
        builder.add(record)
        let sample = try XCTUnwrap(builder.report().samples.first)
        var options = record.options
        options.useLocalPlane = false
        let expectedA = LiDARMeasurementEngine(options: options).measure(frame: record.snapshot.frame, landmarks: record.landmarks, definitions: record.definitions)
        options.useLocalPlane = true
        let expectedB = LiDARMeasurementEngine(options: options).measure(frame: record.snapshot.frame, landmarks: record.landmarks, definitions: record.definitions)
        XCTAssertEqual(sample.baseline.meters, expectedA.values.first?.meters)
        XCTAssertEqual(sample.stabilized.meters, expectedB.values.first?.meters)
        XCTAssertLessThan(try XCTUnwrap(sample.stabilized.meters), 1)
    }

    func testMixedErrorSignsAndP95AreComputedWithoutCancellation() throws {
        var builder = BaselineReportBuilder()
        for reference in [49.0, 52.0, 47.0] { builder.add(fixture(reference: reference)) }
        let value = builder.report().stabilized
        XCTAssertEqual(try XCTUnwrap(value.meanAbsoluteErrorCentimeters), 2, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(value.meanSignedErrorCentimeters), 2.0 / 3, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(value.percentile95AbsoluteErrorCentimeters), 3, accuracy: 0.05)
    }

    func testInvalidReferenceAndAmbiguousMultiDefinitionDoNotProduceAccuracy() {
        var builder = BaselineReportBuilder()
        builder.add(fixture(reference: -10))
        builder.add(fixture(reference: .infinity))
        var multi = fixture()
        multi.definitions.append(.longSleeve[0])
        builder.add(multi)
        let report = builder.report()
        XCTAssertEqual(report.malformedRecords, 1)
        XCTAssertEqual(report.stabilized.referencedAttempts, 0)
        XCTAssertNil(report.stabilized.meanAbsoluteErrorCentimeters)
    }

    func testCSVIncludesFailuresEscapesTextAndNeutralizesFormulas() {
        var record = fixture(missing: true)
        record.testContext?.specimenName = "=SUM(1,2)"
        record.testContext?.conditions = "a,\"b\"\nnew line"
        var builder = BaselineReportBuilder()
        builder.add(record)
        let csv = builder.report().csv
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\""))
        XCTAssertTrue(csv.contains("\"a,\"\"b\"\"\nnew line\""))
        XCTAssertTrue(csv.contains("\"unavailable\",\"insufficientDepth\""))
        XCTAssertTrue(csv.contains("\"50.0000\",\"\""))
    }

    func testOldRecordsDecodeWithoutNewContextAndNewContextRoundTrips() throws {
        let original = fixture()
        let bytes = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SavedMeasurement.self, from: bytes)
        XCTAssertEqual(restored.testContext, original.testContext)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "testContext")
        let old = try JSONDecoder().decode(SavedMeasurement.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.testContext)
    }

    func testCorruptRecordDoesNotHideHealthyArchiveOrReport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = MeasurementArchive(folder: folder)
        _ = try await archive.save(fixture())
        let bad = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: bad.appendingPathComponent("summary.json"))
        try Data("bad".utf8).write(to: bad.appendingPathComponent("measurement.json"))
        let summaries = try await archive.summaries()
        XCTAssertEqual(summaries.count, 1)
        let report = try await archive.baselineReport()
        XCTAssertEqual(report.samples.count, 1)
        XCTAssertEqual(report.malformedRecords, 1)
    }

    func testCompanionReplayUsesSamePointsOptionsAndPlaneSetting() throws {
        var record = pairedFixture(smoothedScale: 1.1)
        record.options.sampleRadius = 4
        record.options.minimumSamples = 8
        record.options.useLocalPlane = false
        record.result.values[0].meters = 999
        var builder = BaselineReportBuilder()
        builder.add(record)
        let report = builder.report()
        let sample = try XCTUnwrap(report.samples.first)
        var options = record.options
        options.useLocalPlane = true
        let expected = LiDARMeasurementEngine(options: options).measure(
            frame: try XCTUnwrap(record.snapshot.smoothedFrame), landmarks: record.landmarks, definitions: record.definitions)
        XCTAssertEqual(sample.smoothedPairStatus, .paired)
        XCTAssertEqual(sample.smoothed?.meters, expected.values.first?.meters)
        XCTAssertEqual(sample.smoothed?.points.map(\.id), sample.stabilized.points.map(\.id))
        XCTAssertEqual(report.pairedRaw.attempts, 1)
        XCTAssertEqual(report.pairedSmoothed.attempts, 1)
        XCTAssertEqual(try XCTUnwrap(report.pairedSmoothed.meanAbsoluteErrorCentimeters), 5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(report.pairedRaw.meanAbsoluteErrorCentimeters), 0, accuracy: 0.01)
    }

    func testPairedComparisonKeepsFailureDenominatorAndUsesCommonErrorIntersection() throws {
        var builder = BaselineReportBuilder()
        builder.add(pairedFixture(smoothedScale: 1.1)) // Only this pair has two numeric values and a reference.
        builder.add(pairedFixture(reference: 48, smoothedScale: 0)) // Companion fails.
        var rawFailure = pairedFixture(reference: 52)
        rawFailure.snapshot.frame.depth.values = rawFailure.snapshot.frame.depth.values.map { _ in 0 }
        builder.add(rawFailure) // Primary fails, companion still has valid data.
        builder.add(pairedFixture(reference: nil))
        builder.add(fixture(reference: 90)) // Raw-only evidence must not skew paired MAE.
        let report = builder.report()
        XCTAssertEqual(report.stabilized.attempts, 5)
        XCTAssertEqual(report.missingCompanionRecords, 1)
        XCTAssertEqual(report.pairedRaw.attempts, 4)
        XCTAssertEqual(report.pairedSmoothed.attempts, 4)
        XCTAssertEqual(report.pairedRaw.numericResults, 3)
        XCTAssertEqual(report.pairedSmoothed.numericResults, 3)
        XCTAssertEqual(report.pairedRaw.unavailable, 1)
        XCTAssertEqual(report.pairedSmoothed.unavailable, 1)
        XCTAssertEqual(report.pairedRaw.referencedAttempts, 3)
        XCTAssertEqual(report.pairedSmoothed.referencedAttempts, 3)
        XCTAssertEqual(report.pairedRaw.compared, 1)
        XCTAssertEqual(report.pairedSmoothed.compared, 1)
        XCTAssertEqual(try XCTUnwrap(report.pairedRaw.meanAbsoluteErrorCentimeters), 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(report.pairedSmoothed.meanAbsoluteErrorCentimeters), 5, accuracy: 0.01)
    }

    func testNoPairedReferenceLeavesAccuracyUnavailableButRetainsAttempts() {
        var builder = BaselineReportBuilder()
        builder.add(pairedFixture(reference: nil))
        let report = builder.report()
        XCTAssertEqual(report.pairedRaw.attempts, 1)
        XCTAssertEqual(report.pairedSmoothed.numericResults, 1)
        XCTAssertEqual(report.pairedSmoothed.referencedAttempts, 0)
        XCTAssertEqual(report.pairedRaw.compared, 0)
        XCTAssertNil(report.pairedRaw.meanAbsoluteErrorCentimeters)
        XCTAssertNil(report.pairedSmoothed.meanAbsoluteErrorCentimeters)
    }

    func testLatestDuplicateCorrectionReplacesPairAndReferenceInEitherImportOrder() throws {
        let original = fixture(reference: 50)
        var edited = original
        edited.id = UUID()
        edited.savedAt = original.savedAt.addingTimeInterval(1)
        edited.referenceCentimeters = 48
        var companion = original.snapshot.frame
        companion.source = .smoothedSceneDepth
        edited.snapshot.smoothedFrame = companion
        for records in [[original, edited], [edited, original]] {
            var builder = BaselineReportBuilder()
            records.forEach { builder.add($0) }
            let report = builder.report()
            XCTAssertEqual(report.samples.count, 1)
            XCTAssertEqual(report.duplicateSaves, 1)
            XCTAssertEqual(report.pairedRaw.attempts, 1)
            XCTAssertEqual(report.missingCompanionRecords, 0)
            XCTAssertEqual(report.mismatchedCompanionRecords, 0)
            XCTAssertEqual(report.samples.first?.recordID, edited.id)
            XCTAssertEqual(try XCTUnwrap(report.pairedRaw.meanAbsoluteErrorCentimeters), 2, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(report.pairedSmoothed.meanAbsoluteErrorCentimeters), 2, accuracy: 0.01)
        }
    }

    func testLatestCorruptPairKeepsPrimaryWithoutReusingOlderValidCompanion() {
        let original = pairedFixture()
        var edited = original
        edited.id = UUID()
        edited.savedAt = original.savedAt.addingTimeInterval(1)
        edited.snapshot.smoothedFrame?.timestamp += 1
        for records in [[original, edited], [edited, original]] {
            var builder = BaselineReportBuilder()
            records.forEach { builder.add($0) }
            let report = builder.report()
            XCTAssertEqual(report.stabilized.numericResults, 1)
            XCTAssertEqual(report.pairedRaw.attempts, 0)
            XCTAssertEqual(report.mismatchedCompanionRecords, 1)
            XCTAssertEqual(report.missingCompanionRecords, 0)
            XCTAssertEqual(report.duplicateSaves, 1)
        }
    }

    func testMetadataAndStructuralMismatchesExcludeOnlyCompanion() throws {
        let mutations: [(inout MeasurementFrame) -> Void] = [
            { $0.sessionID = UUID() }, { $0.frameID = UUID() }, { $0.timestamp += 0.01 },
            { $0.capturedAt = $0.capturedAt.addingTimeInterval(0.01) },
            { $0.imageSize.width += 1 }, { $0.intrinsics.fx += 1 },
            { $0.orientation = .right }, { $0.source = .sceneDepth },
            { $0.depth.values.removeLast() }, { $0.depth.confidence?.removeLast() },
            { $0.depth.confidence?[0] = 3 }, { $0.depth.size.width += 1 }
        ]
        for (index, mutate) in mutations.enumerated() {
            var record = pairedFixture()
            var companion = try XCTUnwrap(record.snapshot.smoothedFrame)
            mutate(&companion)
            record.snapshot.smoothedFrame = companion
            var builder = BaselineReportBuilder()
            builder.add(record)
            let report = builder.report()
            XCTAssertEqual(report.stabilized.numericResults, 1, "mutation \(index)")
            XCTAssertEqual(report.pairedRaw.attempts, 0, "mutation \(index)")
            XCTAssertEqual(report.mismatchedCompanionRecords, 1, "mutation \(index)")
            XCTAssertEqual(report.malformedRecords, 0, "Primary remains usable: \(index)")
        }
        var wrongPrimary = pairedFixture()
        wrongPrimary.snapshot.frame.source = .smoothedSceneDepth
        var builder = BaselineReportBuilder()
        builder.add(wrongPrimary)
        XCTAssertEqual(builder.report().mismatchedCompanionRecords, 1)
        XCTAssertEqual(builder.report().stabilized.attempts, 1)
    }

    func testPairedSyntheticAndAutomaticLandmarksRemainExcluded() {
        var synthetic = pairedFixture()
        synthetic.snapshot.frame.source = .synthetic
        var automatic = pairedFixture()
        automatic.landmarks.origin = .model
        var builder = BaselineReportBuilder()
        builder.add(synthetic)
        builder.add(automatic)
        let report = builder.report()
        XCTAssertEqual(report.syntheticRecords, 1)
        XCTAssertEqual(report.nonManualRecords, 1)
        XCTAssertEqual(report.pairedSamples.count, 0)
        XCTAssertEqual(report.missingCompanionRecords, 0)
        XCTAssertEqual(report.mismatchedCompanionRecords, 0)
    }

    func testCSVAppendsPairedColumnsAndPreservesExistingIndexesAndFailureRows() {
        var builder = BaselineReportBuilder()
        builder.add(pairedFixture(smoothedScale: 0))
        // This fixture has no commas, quotes, or newlines in string fields, so splitting is sufficient here.
        let lines = builder.report().csv.components(separatedBy: "\r\n")
        let headers = lines[0].components(separatedBy: ",")
        let row = lines[1].components(separatedBy: ",")
        XCTAssertEqual(headers.count, 27)
        XCTAssertEqual(row.count, headers.count)
        XCTAssertEqual(headers[9], "\"reference_cm\"")
        XCTAssertEqual(headers[18], "\"algorithm_version\"")
        XCTAssertEqual(headers[19], "\"smoothed_pair_status\"")
        XCTAssertEqual(headers[24], "\"paired_error_eligible\"")
        XCTAssertEqual(row[19], "\"paired\"")
        XCTAssertEqual(row[20], "\"\"")
        XCTAssertEqual(row[21], "\"unavailable\"")
        XCTAssertEqual(row[22], "\"insufficientDepth\"")
        XCTAssertEqual(row[24], "\"false\"")
        XCTAssertEqual(row[25], "\"\"")
        XCTAssertEqual(row[26], "\"\"")
    }
}
