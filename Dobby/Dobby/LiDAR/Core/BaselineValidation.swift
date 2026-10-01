import Foundation

/// User-entered test conditions. Optional in schema v1 so older records still open.
nonisolated struct MeasurementTestContext: Codable, Sendable, Equatable {
    var category: GarmentCategory = .top
    var specimenName = ""
    var deviceModel = ""
    var conditions = ""
}

nonisolated struct BaselineSample: Sendable, Identifiable {
    var recordID: UUID
    var sessionID: UUID
    var frameID: UUID
    var savedAt: Date
    var capturedAt: Date
    var definitionID: String
    var title: String
    var source: DepthSource
    var context: MeasurementTestContext?
    var referenceCentimeters: Double?
    var baseline: MeasurementValue
    var stabilized: MeasurementValue
    var smoothed: MeasurementValue? = nil
    var smoothedPairStatus: SmoothedPairStatus = .missing
    var id: String { "\(sessionID)/\(frameID)/\(definitionID)" }

    /// Accuracy comparisons use the intersection of successful numeric outputs.
    /// Failures still remain in both methods' common attempt denominator.
    var pairedErrorEligible: Bool {
        referenceCentimeters != nil && smoothedPairStatus == .paired
            && Self.hasNumericResult(stabilized) && smoothed.map(Self.hasNumericResult) == true
    }

    fileprivate static func hasNumericResult(_ value: MeasurementValue) -> Bool {
        value.status != .unavailable && value.meters.map { $0.isFinite && $0 > 0 } == true
    }
}

nonisolated enum SmoothedPairStatus: String, Sendable {
    case paired, missing, mismatched
}

nonisolated struct BaselineStatistics: Sendable {
    var attempts: Int
    var valid: Int
    var uncertain: Int
    var unavailable: Int
    var referencedAttempts: Int
    var compared: Int
    var meanAbsoluteErrorCentimeters: Double?
    var percentile95AbsoluteErrorCentimeters: Double?
    var meanSignedErrorCentimeters: Double?
    var qualityAcceptedRate: Double? { attempts > 0 ? Double(valid) / Double(attempts) : nil }

    var numericResults: Int { valid + uncertain }
    var numericResultRate: Double? { attempts > 0 ? Double(numericResults) / Double(attempts) : nil }

    init(samples: [BaselineSample], stabilized: Bool) {
        self.init(entries: samples.map {
            (stabilized ? $0.stabilized : $0.baseline, $0.referenceCentimeters, true)
        })
    }

    fileprivate init(pairedSamples: [BaselineSample], smoothed: Bool) {
        self.init(entries: pairedSamples.compactMap { sample in
            guard sample.smoothedPairStatus == .paired, let companion = sample.smoothed else { return nil }
            return (smoothed ? companion : sample.stabilized, sample.referenceCentimeters, sample.pairedErrorEligible)
        })
    }

    private init(entries: [(result: MeasurementValue, reference: Double?, errorEligible: Bool)]) {
        attempts = entries.count
        valid = 0; uncertain = 0; unavailable = 0
        referencedAttempts = 0
        var errors: [Double] = []
        for entry in entries {
            let result = entry.result
            switch result.status {
            case .valid: valid += 1
            case .uncertain: uncertain += 1
            case .unavailable: unavailable += 1
            }
            guard let reference = entry.reference else { continue }
            referencedAttempts += 1
            // Never convert missing/failed measurements to zero or silently call them successes.
            if entry.errorEligible, BaselineSample.hasNumericResult(result), let meters = result.meters {
                errors.append(meters * 100 - reference)
            }
        }
        compared = errors.count
        if errors.isEmpty {
            meanAbsoluteErrorCentimeters = nil
            percentile95AbsoluteErrorCentimeters = nil
            meanSignedErrorCentimeters = nil
        } else {
            let absolute = errors.map(abs).sorted()
            meanAbsoluteErrorCentimeters = absolute.reduce(0, +) / Double(absolute.count)
            // Nearest-rank P95 is defined even for a small sample; no fabricated precision.
            percentile95AbsoluteErrorCentimeters = absolute[max(0, Int(ceil(Double(absolute.count) * 0.95)) - 1)]
            meanSignedErrorCentimeters = errors.reduce(0, +) / Double(errors.count)
        }
    }
}

nonisolated struct BaselineReport: Sendable {
    var samples: [BaselineSample]
    var syntheticRecords: Int
    var nonManualRecords: Int
    var malformedRecords: Int
    var duplicateSaves: Int
    var algorithmVersion: String
    var baseline: BaselineStatistics { .init(samples: samples, stabilized: false) }
    var stabilized: BaselineStatistics { .init(samples: samples, stabilized: true) }
    var pairedSamples: [BaselineSample] { samples.filter { $0.smoothedPairStatus == .paired && $0.smoothed != nil } }
    var pairedRaw: BaselineStatistics { .init(pairedSamples: pairedSamples, smoothed: false) }
    var pairedSmoothed: BaselineStatistics { .init(pairedSamples: pairedSamples, smoothed: true) }
    var missingCompanionRecords: Int { samples.filter { $0.smoothedPairStatus == .missing }.count }
    var mismatchedCompanionRecords: Int { samples.filter { $0.smoothedPairStatus == .mismatched }.count }

    /// Detail rows preserve failures and missing references. Spreadsheet formulas
    /// in user-entered fields are neutralized before CSV export.
    var csv: String {
        let header = ["record_id", "frame_id", "captured_at", "source", "device", "garment_category", "specimen", "conditions", "measurement", "reference_cm", "baseline_cm", "baseline_status", "baseline_failure", "stabilized_cm", "stabilized_status", "stabilized_failure", "baseline_error_cm", "stabilized_error_cm", "algorithm_version", "smoothed_pair_status", "smoothed_cm", "smoothed_status", "smoothed_failure", "smoothed_error_cm", "paired_error_eligible", "paired_raw_error_cm", "paired_smoothed_error_cm"]
        let formatter = ISO8601DateFormatter()
        var rows = [header]
        for sample in samples {
            let a = sample.baseline.meters.map { $0 * 100 }, b = sample.stabilized.meters.map { $0 * 100 }
            let smoothed = sample.smoothed?.meters.map { $0 * 100 }
            let smoothedError = sample.referenceCentimeters.flatMap { reference in smoothed.map { $0 - reference } }
            let rawError = sample.referenceCentimeters.flatMap { reference in b.map { $0 - reference } }
            rows.append([
                sample.recordID.uuidString, sample.frameID.uuidString, formatter.string(from: sample.capturedAt),
                sample.source.rawValue, Self.safeCell(sample.context?.deviceModel ?? ""), sample.context?.category.rawValue ?? "",
                Self.safeCell(sample.context?.specimenName ?? ""), Self.safeCell(sample.context?.conditions ?? ""), Self.safeCell(sample.title),
                Self.number(sample.referenceCentimeters), Self.number(a), sample.baseline.status.rawValue, sample.baseline.failure?.rawValue ?? "",
                Self.number(b), sample.stabilized.status.rawValue, sample.stabilized.failure?.rawValue ?? "",
                Self.number(sample.referenceCentimeters.flatMap { reference in a.map { $0 - reference } }),
                Self.number(rawError), algorithmVersion,
                sample.smoothedPairStatus.rawValue, Self.number(smoothed), sample.smoothed?.status.rawValue ?? "",
                sample.smoothed?.failure?.rawValue ?? "", Self.number(smoothedError), sample.pairedErrorEligible ? "true" : "false",
                Self.number(sample.pairedErrorEligible ? rawError : nil), Self.number(sample.pairedErrorEligible ? smoothedError : nil)
            ])
        }
        return "\u{FEFF}" + rows.map { $0.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func safeCell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, "=+-@".contains(first) else { return value }
        return "'" + value
    }
}

/// Incremental replay avoids holding every record's photograph/depth in memory.
/// The same captured frame and item are counted once, using the latest saved edit.
nonisolated struct BaselineReportBuilder {
    private var rows: [String: BaselineSample] = [:]
    private var synthetic = 0, nonManual = 0, malformed = 0, duplicates = 0
    private var version = ""

    mutating func addUnreadableRecord() { malformed += 1 }

    mutating func add(_ record: SavedMeasurement) {
        guard record.snapshot.frame.source != .synthetic else { synthetic += 1; return }
        guard record.landmarks.origin == .manual else { nonManual += 1; return }
        guard record.definitions.count == 1, let definition = record.definitions.first,
              definition.landmarkIDs.count >= 2,
              record.snapshot.frame.sessionID == record.landmarks.sessionID,
              record.snapshot.frame.frameID == record.landmarks.frameID else { malformed += 1; return }
        var options = record.options
        options.useLocalPlane = false
        let baselineResult = LiDARMeasurementEngine(options: options).measure(
            frame: record.snapshot.frame, landmarks: record.landmarks, definitions: [definition])
        options.useLocalPlane = true
        let stabilizedResult = LiDARMeasurementEngine(options: options).measure(
            frame: record.snapshot.frame, landmarks: record.landmarks, definitions: [definition])
        guard let baseline = baselineResult.values.first, let stabilized = stabilizedResult.values.first else {
            malformed += 1; return
        }
        version = stabilizedResult.algorithmVersion
        let reference = record.referenceCentimeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let (smoothed, pairStatus) = replayCompanion(record, definition: definition, options: options)
        let sample = BaselineSample(recordID: record.id, sessionID: record.snapshot.frame.sessionID,
            frameID: record.snapshot.frame.frameID, savedAt: record.savedAt, capturedAt: record.snapshot.frame.capturedAt,
            definitionID: definition.id, title: definition.title, source: record.snapshot.frame.source,
            context: record.testContext, referenceCentimeters: reference, baseline: baseline, stabilized: stabilized,
            smoothed: smoothed, smoothedPairStatus: pairStatus)
        if let previous = rows[sample.id] {
            duplicates += 1
            // UUID tie-break makes imports with identical savedAt deterministic.
            if previous.savedAt > sample.savedAt || (previous.savedAt == sample.savedAt && previous.recordID.uuidString > sample.recordID.uuidString) { return }
        }
        rows[sample.id] = sample
    }

    private func replayCompanion(_ record: SavedMeasurement, definition: MeasurementDefinition,
                                 options: MeasurementOptions) -> (MeasurementValue?, SmoothedPairStatus) {
        guard let companion = record.snapshot.smoothedFrame else { return (nil, .missing) }
        let primary = record.snapshot.frame
        guard primary.source == .sceneDepth, companion.source == .smoothedSceneDepth,
              primary.sessionID == companion.sessionID, primary.frameID == companion.frameID,
              primary.timestamp.isFinite, primary.timestamp == companion.timestamp,
              primary.capturedAt == companion.capturedAt, primary.imageSize == companion.imageSize,
              primary.intrinsics == companion.intrinsics, primary.orientation == companion.orientation,
              validCompanionMap(companion) else { return (nil, .mismatched) }
        // Both depth sources use the same points, saved options, and local-plane setting.
        // No depth threshold, calibration factor, or point is tuned using the reference length.
        let result = LiDARMeasurementEngine(options: options).measure(
            frame: companion, landmarks: record.landmarks, definitions: [definition])
        guard let value = result.values.first else { return (nil, .mismatched) }
        return (value, .paired)
    }

    private func validCompanionMap(_ frame: MeasurementFrame) -> Bool {
        let map = frame.depth
        guard map.size.isValid, frame.imageSize.isValid,
              map.size.width * frame.imageSize.height == map.size.height * frame.imageSize.width,
              map.values.count == map.size.width * map.size.height else { return false }
        if let confidence = map.confidence {
            guard confidence.count == map.values.count, confidence.allSatisfy({ $0 <= 2 }) else { return false }
        }
        // Zero/invalid depth samples are sensor failures, not a broken frame contract.
        return true
    }

    func report() -> BaselineReport {
        .init(samples: rows.values.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt
        }, syntheticRecords: synthetic, nonManualRecords: nonManual, malformedRecords: malformed,
              duplicateSaves: duplicates, algorithmVersion: version)
    }
}
