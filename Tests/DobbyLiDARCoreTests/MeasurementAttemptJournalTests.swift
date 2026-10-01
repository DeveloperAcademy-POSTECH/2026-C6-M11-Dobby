import XCTest
@testable import DobbyLiDARCore

final class MeasurementAttemptJournalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dobby-attempt-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testCaptureFailureWithoutSnapshotIsPersistedAndCounted() async throws {
        let folder = try temporaryFolder()
        let journal = MeasurementAttemptJournal(folder: folder)
        let attempt = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        _ = try await journal.finish(id: attempt.id, outcome: .captureFailed, phase: .capture,
                                     timings: .init(captureSeconds: 2), message: "권한 거부", finishedAt: start.addingTimeInterval(2))
        let restored = MeasurementAttemptJournal(folder: folder)
        let report = try await restored.report()
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.physical.captureFailures, 1)
        XCTAssertEqual(report.physical.failureCount, 1)
        XCTAssertEqual(report.physical.captureLatency.sampleCount, 0)
        XCTAssertEqual(report.physical.totalLatency.medianSeconds, 2)
        XCTAssertNil(report.records[0].sessionID)
        XCTAssertNil(report.records[0].frameID)
        XCTAssertEqual(report.records[0].message, "권한 거부")
    }

    func testDuplicateBeginAndFinishDoNotInflateOrRewriteOutcome() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        let id = UUID()
        let first = try await journal.begin(id: id, purpose: .manualSensor, isSynthetic: false, startedAt: start)
        let duplicate = try await journal.begin(id: id, purpose: .manualSensor, isSynthetic: false,
                                                startedAt: start.addingTimeInterval(1))
        XCTAssertEqual(first, duplicate)
        let terminal = try await journal.finish(id: id, outcome: .success, phase: .capture,
                                                timings: .init(captureSeconds: 0.4), finishedAt: start.addingTimeInterval(1))
        let repeated = try await journal.finish(id: id, outcome: .cancelled, phase: .capture,
                                                message: "late cancellation", finishedAt: start.addingTimeInterval(2))
        XCTAssertEqual(terminal, repeated)
        let update = try await journal.update(id: id, phase: .measurement, timings: .init(measurementSeconds: 99))
        XCTAssertEqual(update, terminal)
        let report = try await journal.report()
        XCTAssertEqual(report.physical.totalAttempts, 1)
        XCTAssertEqual(report.physical.successfulAttempts, 1)
        XCTAssertEqual(report.physical.cancellations, 0)
        XCTAssertNil(report.physical.geometrySuccessRateExcludingCancellations)
    }

    func testConcurrentFinishesPreserveOneTerminalResult() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        let finishedAt = start.addingTimeInterval(1)
        let results = try await withThrowingTaskGroup(of: MeasurementAttemptRecord.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await journal.finish(id: record.id, outcome: index.isMultiple(of: 2) ? .cancelled : .captureFailed,
                                             phase: .capture, message: "completion \(index)", finishedAt: finishedAt)
                }
            }
            var results = [MeasurementAttemptRecord]()
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy { $0 == results.first })
        let report = try await journal.report()
        XCTAssertEqual(report.physical.totalAttempts, 1)
        XCTAssertEqual(report.physical.finishedAttempts, 1)
    }

    func testRestoredPendingAttemptStaysUnfinishedWithCompletedPriorStageTiming() async throws {
        let folder = try temporaryFolder()
        let journal = MeasurementAttemptJournal(folder: folder)
        let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        let session = UUID(), frame = UUID()
        _ = try await journal.update(id: record.id, phase: .landmarks, sessionID: session, frameID: frame,
                                     timings: .init(captureSeconds: 0.3, landmarksSeconds: 99))
        let restored = MeasurementAttemptJournal(folder: folder)
        let report = try await restored.report()
        XCTAssertEqual(report.physical.unfinishedAttempts, 1)
        XCTAssertEqual(report.physical.failureCount, 0)
        XCTAssertEqual(report.physical.interruptions, 0)
        XCTAssertEqual(report.physical.captureLatency.medianSeconds, 0.3)
        XCTAssertEqual(report.physical.landmarksLatency.sampleCount, 0)
        XCTAssertEqual(report.physical.totalLatency.sampleCount, 0)
        XCTAssertNil(report.records[0].finishedAt)
        XCTAssertEqual(report.records[0].frameID, frame)
        XCTAssertEqual(report.records[0].sessionID, session)
    }

    func testCancellationIsSeparateFromFailureAndExcludedFromAutomaticSuccessDenominator() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        for outcome in [MeasurementAttemptOutcome.success, .captureFailed, .cancelled, .partial] {
            let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
            _ = try await journal.finish(id: record.id, outcome: outcome,
                                         phase: outcome == .captureFailed || outcome == .cancelled ? .capture : .measurement,
                                         finishedAt: start.addingTimeInterval(1))
        }
        // A manual capture success must not improve the automatic-measurement rate.
        let manual = try await journal.begin(purpose: .manualSensor, isSynthetic: false, startedAt: start)
        _ = try await journal.finish(id: manual.id, outcome: .success, phase: .capture, finishedAt: start.addingTimeInterval(1))
        let report = try await journal.report()
        XCTAssertEqual(report.physical.totalAttempts, 5)
        XCTAssertEqual(report.physical.failureCount, 1)
        XCTAssertEqual(report.physical.cancellations, 1)
        XCTAssertEqual(report.physical.partialAttempts, 1)
        XCTAssertEqual(report.physical.successfulAttempts, 2)
        XCTAssertEqual(report.physical.automaticFinishedAttempts, 4)
        XCTAssertEqual(report.physical.geometrySuccessRateExcludingCancellations ?? 0, 1.0 / 3, accuracy: 1e-8)
        XCTAssertNil(report.manualSensor.geometrySuccessRateExcludingCancellations)
    }

    func testSyntheticRecordsCannotImprovePhysicalMetrics() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        for purpose in [MeasurementAttemptPurpose.fixture, .automaticModel, .manualSensor] {
            let record = try await journal.begin(purpose: purpose, isSynthetic: true, startedAt: start)
            _ = try await journal.finish(id: record.id, outcome: .success, phase: .measurement,
                                         timings: .init(captureSeconds: 0.01, landmarksSeconds: 0.01,
                                                        measurementSeconds: 0.01), finishedAt: start.addingTimeInterval(1))
        }
        let physical = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        _ = try await journal.finish(id: physical.id, outcome: .timedOut, phase: .capture, finishedAt: start.addingTimeInterval(4))
        let report = try await journal.report()
        XCTAssertEqual(report.synthetic.totalAttempts, 3)
        XCTAssertEqual(report.physical.totalAttempts, 1)
        XCTAssertEqual(report.physical.timeouts, 1)
        XCTAssertEqual(report.physical.captureLatency.sampleCount, 0)
        XCTAssertEqual(report.physical.geometrySuccessRateExcludingCancellations, 0)
        do {
            _ = try await journal.begin(purpose: .fixture, isSynthetic: false, startedAt: start)
            XCTFail("A fixture must never be identified as a physical attempt")
        } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .invalidRecord) }
    }

    func testOnlyCompletedStagesContributeMedianAndNearestRankP95() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        for value in 1...20 {
            let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
            _ = try await journal.finish(id: record.id, outcome: .success, phase: .measurement,
                                         timings: .init(captureSeconds: Double(value), landmarksSeconds: Double(value) / 2,
                                                        measurementSeconds: 0.1, totalSeconds: 100),
                                         finishedAt: start.addingTimeInterval(100))
        }
        let failed = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        _ = try await journal.finish(id: failed.id, outcome: .landmarkFailed, phase: .landmarks,
                                     timings: .init(captureSeconds: 21, landmarksSeconds: 999, measurementSeconds: 999),
                                     finishedAt: start.addingTimeInterval(1_020))
        let report = try await journal.report()
        XCTAssertEqual(report.physical.captureLatency.sampleCount, 21)
        XCTAssertEqual(report.physical.captureLatency.medianSeconds, 11)
        XCTAssertEqual(report.physical.captureLatency.p95Seconds, 20)
        XCTAssertEqual(report.physical.landmarksLatency.sampleCount, 20)
        XCTAssertEqual(report.physical.landmarksLatency.medianSeconds, 5.25)
        XCTAssertEqual(report.physical.landmarksLatency.p95Seconds, 9.5)
        XCTAssertEqual(report.physical.measurementLatency.sampleCount, 20)
    }

    func testInvalidTimingsDoNotPoisonPersistenceOrLatencyStatistics() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        _ = try await journal.update(id: record.id, phase: .capture, timings: .init(totalSeconds: 0.2))
        let terminal = try await journal.finish(id: record.id, outcome: .success, phase: .measurement,
                                                timings: .init(captureSeconds: .nan, landmarksSeconds: .infinity,
                                                               measurementSeconds: -1, totalSeconds: .nan),
                                                finishedAt: start.addingTimeInterval(2))
        XCTAssertNil(terminal.timings.captureSeconds)
        XCTAssertNil(terminal.timings.landmarksSeconds)
        XCTAssertNil(terminal.timings.measurementSeconds)
        XCTAssertEqual(terminal.timings.totalSeconds, 2)
        let report = try await journal.report()
        XCTAssertEqual(report.physical.captureLatency.sampleCount, 0)
        XCTAssertNil(report.physical.measurementLatency.p95Seconds)
        XCTAssertTrue(terminal.hasCompleted(.measurement))
    }

    func testUnavailableCaptureIsNotACompletedCaptureButEvaluatedUnavailableMeasurementIsTimed() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        let camera = try await journal.begin(purpose: .manualSensor, isSynthetic: false, startedAt: start)
        let cameraResult = try await journal.finish(id: camera.id, outcome: .unavailable, phase: .capture,
                                                    timings: .init(captureSeconds: 2), finishedAt: start.addingTimeInterval(2))
        XCTAssertFalse(cameraResult.hasCompleted(.capture))
        let measurement = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        let measurementResult = try await journal.finish(id: measurement.id, outcome: .unavailable, phase: .measurement,
                                                         timings: .init(measurementSeconds: 0.1), finishedAt: start.addingTimeInterval(2))
        XCTAssertTrue(measurementResult.hasCompleted(.measurement))
        let report = try await journal.report()
        XCTAssertEqual(report.physical.captureLatency.sampleCount, 0)
        XCTAssertEqual(report.physical.measurementLatency.sampleCount, 1)
        XCTAssertEqual(report.physical.unavailableAttempts, 2)
    }

    func testInvalidDatesAndRegressiveTransitionsLeavePersistedAttemptIntact() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        do {
            _ = try await journal.begin(purpose: .manualSensor, isSynthetic: false,
                                         startedAt: Date(timeIntervalSince1970: .nan))
            XCTFail("nonfinite start date")
        } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .invalidRecord) }
        let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false, startedAt: start)
        _ = try await journal.update(id: record.id, phase: .landmarks, timings: .init(captureSeconds: 0.1))
        do {
            _ = try await journal.update(id: record.id, phase: .capture)
            XCTFail("phase regression")
        } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .invalidTransition) }
        for date in [start.addingTimeInterval(-1), Date(timeIntervalSince1970: .infinity)] {
            do {
                _ = try await journal.finish(id: record.id, outcome: .cancelled, phase: .landmarks, finishedAt: date)
                XCTFail("invalid finish date")
            } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .invalidRecord) }
        }
        let report = try await journal.report()
        XCTAssertEqual(report.physical.unfinishedAttempts, 1)
        XCTAssertEqual(report.physical.finishedAttempts, 0)
    }

    func testCSVContainsEachActualAttemptOnceEscapesMessagesAndKeepsProvenance() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        let record = try await journal.begin(purpose: .automaticModel, isSynthetic: false,
                                             deviceContext: "=device()", startedAt: start)
        _ = try await journal.finish(id: record.id, outcome: .captureFailed, phase: .capture,
                                     message: "=formula(\"x,y\")\nnext", finishedAt: start.addingTimeInterval(1))
        _ = try await journal.finish(id: record.id, outcome: .success, phase: .measurement)
        let report = try await journal.report()
        XCTAssertEqual(report.csv.components(separatedBy: record.id.uuidString).count - 1, 1)
        XCTAssertTrue(report.csv.contains("\"'=device()\""))
        XCTAssertTrue(report.csv.contains("\"'=formula(\"\"x,y\"\")\nnext\""))
        XCTAssertTrue(report.csv.contains("\"false\",\"capture\",\"captureFailed\""))
        let exported = try await journal.exportCSV()
        addTeardownBlock { try? FileManager.default.removeItem(at: exported) }
        XCTAssertEqual(try String(contentsOf: exported, encoding: .utf8), report.csv)
    }

    func testUnreadableOversizedAndMismatchedFilesAreReportedWithoutInventedAttempts() async throws {
        let folder = try temporaryFolder()
        let journal = MeasurementAttemptJournal(folder: folder)
        let record = try await journal.begin(purpose: .manualSensor, isSynthetic: false, startedAt: start)
        try Data(repeating: 0, count: 65_537).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        try JSONEncoder().encode(record).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"))
        let report = try await journal.report()
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.unreadableRecordCount, 2)
        XCTAssertEqual(report.physical.unfinishedAttempts, 1)
        XCTAssertEqual(report.physical.failureCount, 0)
    }

    func testBoundedScanIsExplicitAndConflictingIDCannotChangeProvenance() async throws {
        let folder = try temporaryFolder()
        let journal = MeasurementAttemptJournal(folder: folder)
        let record = try await journal.begin(purpose: .manualSensor, isSynthetic: false, startedAt: start)
        _ = try await journal.begin(purpose: .manualSensor, isSynthetic: false, startedAt: start)
        do {
            _ = try await journal.begin(id: record.id, purpose: .fixture, isSynthetic: true, startedAt: start)
            XCTFail("ID provenance cannot change")
        } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .conflictingAttempt) }
        let limited = MeasurementAttemptJournal(folder: folder, maximumScannedEntries: 1)
        let report = try await limited.report()
        XCTAssertTrue(report.scanLimitReached)
        XCTAssertEqual(report.records.count, 1)
    }

    func testMissingBeginCannotSilentlyCreateTerminalOnlyAttempt() async throws {
        let journal = MeasurementAttemptJournal(folder: try temporaryFolder())
        do {
            _ = try await journal.finish(id: UUID(), outcome: .captureFailed, phase: .capture)
            XCTFail("begin must persist before work")
        } catch { XCTAssertEqual(error as? MeasurementAttemptJournalError, .notFound) }
        let report = try await journal.report()
        XCTAssertEqual(report.physical.totalAttempts, 0)
    }
}
