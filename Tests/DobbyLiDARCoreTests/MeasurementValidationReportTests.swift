import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Fixtures are fabricated to test bookkeeping. They are never physical accuracy evidence.
final class MeasurementValidationReportTests: XCTestCase {
    private func fixture(reference: Double? = 50, missing: Bool = false) -> SavedMeasurement {
        var scene = SyntheticFixtures.scene(missingDepth: missing)
        scene.frame.frameID = UUID()
        scene.landmarks.frameID = scene.frame.frameID
        scene.frame.source = .sceneDepth
        scene.landmarks.origin = .manual
        return .init(id: UUID(), savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            snapshot: .init(frame: scene.frame, imageJPEG: Data("fixture image".utf8)), landmarks: scene.landmarks,
            definitions: [.testDistance],
            result: LiDARMeasurementEngine().measure(frame: scene.frame, landmarks: scene.landmarks, definitions: [.testDistance]),
            referenceCentimeters: reference, options: .init(),
            testContext: .init(category: .top, specimenName: "test specimen", deviceModel: "test device", conditions: "test condition"))
    }

    private func automatic(_ manual: SavedMeasurement, addedCentimeters: Double = 0) -> SavedMeasurement {
        var record = manual
        record.id = UUID()
        record.savedAt = record.savedAt.addingTimeInterval(1)
        record.landmarks.origin = .model
        record.landmarks.modelVersion = "fixture-model-v1"
        if addedCentimeters != 0 {
            // The fixture's optical plane is at exactly 1.15 m.
            record.landmarks.points[1].point.x += (addedCentimeters / 100) * record.snapshot.frame.intrinsics.fx
                / (1.15 * Double(record.snapshot.frame.imageSize.width))
        }
        return record
    }

    func testEmptyAndUnreferencedReportsNeverDeclareCompletedAccuracy() {
        let empty = MeasurementValidationReportBuilder().report()
        XCTAssertTrue(empty.statusSummary.contains("검증 대기"))
        XCTAssertNil(empty.manual.meanAbsoluteErrorCentimeters)
        XCTAssertNil(empty.automated.numericResultRate)
        var builder = MeasurementValidationReportBuilder()
        builder.add(fixture(reference: nil))
        let report = builder.report()
        XCTAssertEqual(report.manual.attempts, 1)
        XCTAssertEqual(report.manual.compared, 0)
        XCTAssertTrue(report.statusSummary.contains("정확도 검증 대기"))
        XCTAssertEqual(report.groups.first?.assessment, .awaitingReference)
    }

    func testMultipleDefinitionsUseIndividualReferencesAndRetainPartialFailure() throws {
        var record = fixture(reference: 999)
        record.definitions.append(.init(id: "missing-point", title: "Another length", landmarkIDs: ["A", "C"]))
        record.referenceByDefinitionCentimeters = ["test": 49, "missing-point": 80]
        var builder = MeasurementValidationReportBuilder()
        builder.add(record)
        let report = builder.report()
        XCTAssertEqual(report.manual.attempts, 2)
        XCTAssertEqual(report.manual.referencedAttempts, 2)
        XCTAssertEqual(report.manual.compared, 1)
        XCTAssertEqual(report.manual.unavailable, 1)
        XCTAssertEqual(try XCTUnwrap(report.manual.meanAbsoluteErrorCentimeters), 1, accuracy: 0.001)
        let missing = try XCTUnwrap(report.samples.first { $0.definitionID == "missing-point" })
        XCTAssertEqual(missing.referenceCentimeters, 80)
        XCTAssertEqual(missing.value.failure, .missingLandmark)
        XCTAssertNil(missing.centimeters)
    }

    func testLegacyScalarIsSingleDefinitionOnlyAndNewMapIsAuthoritative() {
        var record = fixture(reference: 50)
        record.definitions.append(.init(id: "other", title: "Other", landmarkIDs: ["A", "B"]))
        var builder = MeasurementValidationReportBuilder()
        builder.add(record)
        XCTAssertEqual(builder.report().manual.referencedAttempts, 0)

        var mapped = fixture(reference: 50)
        mapped.referenceByDefinitionCentimeters = ["unrelated": 80]
        var other = MeasurementValidationReportBuilder()
        other.add(mapped)
        XCTAssertEqual(other.report().manual.referencedAttempts, 0)
        mapped.referenceByDefinitionCentimeters = ["test": -20]
        var invalid = MeasurementValidationReportBuilder()
        invalid.add(mapped)
        XCTAssertEqual(invalid.report().manual.referencedAttempts, 0)
    }

    func testReplayIgnoresSavedResultsAndPreservesProductionOptions() throws {
        var record = fixture()
        record.result.values[0].meters = 999
        record.options.useLocalPlane = false
        var builder = MeasurementValidationReportBuilder()
        builder.add(record)
        let report = builder.report()
        XCTAssertEqual(report.manual.valid, 0)
        XCTAssertEqual(report.manual.uncertain, 1)
        XCTAssertEqual(try XCTUnwrap(report.samples.first?.centimeters), 50, accuracy: 0.001)
        XCTAssertTrue(report.groups[0].key.optionsFingerprint.contains("\"useLocalPlane\":false"))
    }

    func testSyntheticUnidentifiedModelsAndUnreadableRecordsRemainExcluded() {
        var syntheticSource = fixture()
        syntheticSource.snapshot.frame.source = .synthetic
        var syntheticLandmarks = fixture()
        syntheticLandmarks.landmarks.origin = .synthetic
        var missingVersion = automatic(fixture())
        missingVersion.landmarks.modelVersion = " \n "
        var builder = MeasurementValidationReportBuilder()
        builder.add(syntheticSource)
        builder.add(syntheticLandmarks)
        builder.add(missingVersion)
        builder.addUnreadableRecord()
        builder.add(fixture())
        builder.add(automatic(fixture()))
        let report = builder.report()
        XCTAssertEqual(report.counts.recordsSeen, 6)
        XCTAssertEqual(report.counts.syntheticRecords, 2)
        XCTAssertEqual(report.counts.modelMetadataMissingRecords, 1)
        XCTAssertEqual(report.counts.malformedRecords, 1)
        XCTAssertEqual(report.manual.attempts, 1)
        XCTAssertEqual(report.automated.attempts, 1)
    }

    func testLatestEditDeduplicatesPerFrameDefinitionAndOriginInEitherOrder() throws {
        let original = fixture()
        var edited = original
        edited.id = UUID()
        edited.savedAt = original.savedAt.addingTimeInterval(2)
        edited.referenceCentimeters = 48
        let model = automatic(original)
        for records in [[original, edited, model], [model, edited, original]] {
            var builder = MeasurementValidationReportBuilder()
            records.forEach { builder.add($0) }
            let report = builder.report()
            XCTAssertEqual(report.samples.count, 2)
            XCTAssertEqual(report.counts.duplicateSamples, 1)
            XCTAssertEqual(report.manual.attempts, 1)
            XCTAssertEqual(report.automated.attempts, 1)
            XCTAssertEqual(report.samples.first { $0.origin == .manual }?.recordID, edited.id)
            XCTAssertEqual(try XCTUnwrap(report.manual.meanAbsoluteErrorCentimeters), 2, accuracy: 0.001)
            XCTAssertEqual(report.counts.pairedComparisons, 1)
            XCTAssertNil(report.pairs.first?.sharedReferenceCentimeters)
        }
    }

    func testLatestModelEditWithoutVersionDoesNotResurrectOlderTraceableResult() {
        let original = automatic(fixture())
        var edited = original
        edited.id = UUID()
        edited.savedAt = original.savedAt.addingTimeInterval(1)
        edited.landmarks.modelVersion = nil
        for records in [[original, edited], [edited, original]] {
            var builder = MeasurementValidationReportBuilder()
            records.forEach { builder.add($0) }
            let report = builder.report()
            XCTAssertEqual(report.automated.attempts, 0)
            XCTAssertEqual(report.counts.modelMetadataMissingRecords, 1)
            XCTAssertEqual(report.counts.duplicateSamples, 1)
        }
    }

    func testAutomaticManualDisagreementIsSeparateFromPhysicalTruthError() throws {
        let manual = fixture(reference: 48)
        let model = automatic(manual, addedCentimeters: 2)
        var builder = MeasurementValidationReportBuilder()
        builder.add(manual)
        builder.add(model)
        let report = builder.report()
        let pair = try XCTUnwrap(report.pairs.first)
        XCTAssertEqual(pair.status, .comparable)
        XCTAssertEqual(pair.sharedReferenceCentimeters, 48)
        XCTAssertEqual(try XCTUnwrap(pair.differenceCentimeters), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pair.manualTruthErrorCentimeters), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(pair.automatedTruthErrorCentimeters), 4, accuracy: 0.001)
        XCTAssertTrue(report.markdown.contains("독립 촬영 두 번"))
    }

    func testFailedAutomaticPairStaysInAttemptsWithoutManufacturedDifference() {
        let manual = fixture()
        var model = automatic(manual)
        model.landmarks.points[1].isVisible = false
        var builder = MeasurementValidationReportBuilder()
        builder.add(manual)
        builder.add(model)
        let report = builder.report()
        XCTAssertEqual(report.automated.attempts, 1)
        XCTAssertEqual(report.automated.referencedAttempts, 1)
        XCTAssertEqual(report.automated.compared, 0)
        XCTAssertEqual(report.automated.unavailable, 1)
        XCTAssertEqual(report.counts.pairedUnavailable, 1)
        XCTAssertNil(report.pairs.first?.differenceCentimeters)
    }

    func testMatchingIDsDoNotPermitChangedFramePixelsCalibrationOrOptionsInPairs() {
        let mutations: [(inout SavedMeasurement) -> Void] = [
            { $0.snapshot.frame.depth.values[0] += 0.001 },
            { $0.snapshot.frame.depth.confidence?[0] = 1 },
            { $0.snapshot.frame.intrinsics.fx += 1 },
            { $0.snapshot.frame.timestamp += 0.1 },
            { $0.snapshot.frame.orientation = .right },
            { $0.snapshot.imageJPEG.append(1) },
            { $0.options.sampleRadius = 4 },
            { $0.definitions[0].landmarkIDs.reverse() }
        ]
        for (index, mutate) in mutations.enumerated() {
            let manual = fixture()
            var model = automatic(manual)
            mutate(&model)
            var builder = MeasurementValidationReportBuilder()
            builder.add(manual)
            builder.add(model)
            let report = builder.report()
            XCTAssertEqual(report.counts.pairMismatches, 1, "Mutation \(index)")
            XCTAssertEqual(report.manual.attempts, 1)
            XCTAssertEqual(report.automated.attempts, 1)
            XCTAssertNil(report.pairs.first?.differenceCentimeters)
        }
    }

    func testMissingConditionsStayUnknownAndCannotCreateRepeatEvidence() throws {
        var first = fixture()
        first.testContext = nil
        var second = fixture()
        second.testContext = nil
        var builder = MeasurementValidationReportBuilder()
        builder.add(first)
        builder.add(second)
        let group = try XCTUnwrap(builder.report().groups.first)
        XCTAssertNil(group.key.deviceModel)
        XCTAssertNil(group.key.categoryID)
        XCTAssertNil(group.key.conditions)
        XCTAssertEqual(group.key.categoryTitle, "미기록")
        XCTAssertEqual(group.repetitionCount, 0)
        XCTAssertNil(group.repeatedMeasurementRangeCentimeters)
        XCTAssertNil(group.repeatedMeasurementStandardDeviationCentimeters)
        XCTAssertEqual(group.statistics.attempts, 2)
    }

    func testLiteralContextModelAndOptionsKeepDifferentGroupsSeparate() {
        let mutations: [(inout SavedMeasurement) -> Void] = [
            { $0.testContext?.deviceModel = "other device" },
            { $0.testContext?.category = .dress },
            { $0.testContext?.specimenName = "other garment" },
            { $0.testContext?.conditions = "other condition" },
            { $0.definitions[0].id = "other-definition" },
            { $0.options.useLocalPlane = false },
            { $0.snapshot.frame.source = .smoothedSceneDepth }
        ]
        var builder = MeasurementValidationReportBuilder()
        builder.add(fixture())
        for mutate in mutations {
            var record = fixture()
            mutate(&record)
            builder.add(record)
        }
        builder.add(automatic(fixture()))
        var anotherModel = automatic(fixture())
        anotherModel.landmarks.modelVersion = "fixture-model-v2"
        builder.add(anotherModel)
        XCTAssertEqual(builder.report().groups.count, 10)
    }

    func testRepeatSpreadUsesIndependentNumericFramesAndPreservesFailedAttempts() throws {
        var builder = MeasurementValidationReportBuilder()
        for scale: Float in [1, 1.02, 0.98] {
            var record = fixture()
            record.snapshot.frame.depth.values = record.snapshot.frame.depth.values.map { $0 * scale }
            builder.add(record)
            if scale == 1 {
                record.id = UUID()
                record.savedAt = record.savedAt.addingTimeInterval(1)
                builder.add(record)
            }
        }
        builder.add(fixture(missing: true))
        let report = builder.report()
        let group = try XCTUnwrap(report.groups.first)
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.counts.duplicateSamples, 1)
        XCTAssertEqual(group.statistics.attempts, 4)
        XCTAssertEqual(group.statistics.unavailable, 1)
        XCTAssertEqual(group.repetitionCount, 3)
        XCTAssertEqual(try XCTUnwrap(group.repeatedMeasurementRangeCentimeters), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(group.repeatedMeasurementStandardDeviationCentimeters), 1, accuracy: 0.001)
    }

    func testSmallPerfectSampleCannotPassAndLargerSetStillRequiresHumanReview() throws {
        var builder = MeasurementValidationReportBuilder()
        builder.add(fixture())
        XCTAssertEqual(builder.report().groups.first?.assessment, .insufficientSamples)
        for _ in 1..<MeasurementValidationCriteria.minimumComparedSamples { builder.add(fixture()) }
        let group = try XCTUnwrap(builder.report().groups.first)
        XCTAssertEqual(group.statistics.compared, 30)
        XCTAssertEqual(group.assessment, .requiresHumanReview)
        XCTAssertTrue(builder.report().statusSummary.contains("인수 검토 필요"))
    }

    func testQualityConfidenceDoesNotOverrideLargePhysicalError() throws {
        var builder = MeasurementValidationReportBuilder()
        for _ in 0..<MeasurementValidationCriteria.minimumComparedSamples {
            builder.add(automatic(fixture(reference: 100)))
        }
        let group = try XCTUnwrap(builder.report().groups.first)
        XCTAssertEqual(group.statistics.valid, 30)
        XCTAssertEqual(group.statistics.numericResultRate, 1)
        XCTAssertEqual(try XCTUnwrap(group.statistics.meanAbsoluteErrorCentimeters), 50, accuracy: 0.001)
        XCTAssertEqual(group.assessment, .outsideProposedThresholds)
    }

    func testCSVPreservesFailuresAndNeutralizesUserTextAndMarkdownTables() {
        var record = fixture(missing: true)
        record.testContext?.specimenName = "=SUM(1,2)"
        record.testContext?.conditions = "a,\"b\"\n|injected|"
        var builder = MeasurementValidationReportBuilder()
        builder.add(record)
        let report = builder.report()
        XCTAssertTrue(report.csv.contains("\"'=SUM(1,2)\""))
        XCTAssertTrue(report.csv.contains("\"a,\"\"b\"\"\n|injected|\""))
        XCTAssertTrue(report.csv.contains("\"unavailable\",\"insufficientDepth\""))
        XCTAssertTrue(report.markdown.contains("\\|injected\\|"))
        XCTAssertFalse(report.markdown.contains("\n|injected|"))
    }

    func testKnownErrorSignsProduceMAEAndP95WithoutCancellation() throws {
        var builder = MeasurementValidationReportBuilder()
        [49.0, 52.0, 47.0].forEach { builder.add(fixture(reference: $0)) }
        let stats = builder.report().manual
        XCTAssertEqual(try XCTUnwrap(stats.meanAbsoluteErrorCentimeters), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.percentile95AbsoluteErrorCentimeters), 3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.meanSignedErrorCentimeters), 2.0 / 3, accuracy: 0.001)
    }

    func testMarkdownPairTableShowsSignedDisagreementSeparateTruthAndEscapedTitles() throws {
        var manual = fixture(reference: 48)
        manual.definitions[0].title = "negative|\n[row]"
        var model = automatic(manual, addedCentimeters: -2)
        model.referenceCentimeters = 47

        let failedManual = fixture()
        var failedModel = automatic(failedManual)
        failedModel.landmarks.points[1].isVisible = false

        let mismatchedManual = fixture()
        var mismatchedModel = automatic(mismatchedManual)
        mismatchedModel.snapshot.imageJPEG.append(1)

        let commonManual = fixture()
        let commonModel = automatic(commonManual, addedCentimeters: 1)
        var builder = MeasurementValidationReportBuilder()
        [manual, model, failedManual, failedModel, mismatchedManual, mismatchedModel, commonManual, commonModel].forEach { builder.add($0) }
        let table = try XCTUnwrap(builder.report().markdown.components(separatedBy: "## 같은 촬영의 자동·수동 측정점 비교").last)
        XCTAssertTrue(table.contains("negative\\| \\[row\\] (test)"))
        XCTAssertFalse(table.contains("\n[row]"))
        XCTAssertTrue(table.contains("| 비교 가능 | -2.0000 | 2.0000 | 1.0000 | 공통 없음 |"))
        XCTAssertTrue(table.contains(String(manual.snapshot.frame.frameID.uuidString.prefix(8))))
        XCTAssertTrue(table.contains("| 측정 불가 | — | — | — | — |"))
        XCTAssertTrue(table.contains("| 입력 불일치 | — | — | — | — |"))
        XCTAssertTrue(table.contains("| 50.0000 |"))
        XCTAssertTrue(table.contains("각각 해당 기록에 입력된 줄자 기준값"))

        let empty = MeasurementValidationReportBuilder().report()
        XCTAssertTrue(empty.markdown.contains("실측 기록 없음 · 검증 대기"))
        XCTAssertTrue(empty.markdown.contains("비교할 자동·수동 측정점 쌍이 없습니다."))
    }
}
