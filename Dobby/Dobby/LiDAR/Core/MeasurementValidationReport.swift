import Foundation
import CryptoKit

/// These are suggested review criteria, not a claim of validated device accuracy.
nonisolated enum MeasurementValidationCriteria {
    static let maximumMeanAbsoluteErrorCentimeters = 1.0
    static let maximumP95AbsoluteErrorCentimeters = 2.0
    static let minimumNumericResultRate = 0.90
    static let minimumComparedSamples = 30
    static let description = "제안 기준: MAE ≤ 1 cm, P95 ≤ 2 cm, 수치 산출률 ≥ 90%. 그룹별 줄자 비교 30건 미만은 표본 부족이며, 기준을 만족해도 최종 인수 검토가 필요합니다."
}

nonisolated enum MeasurementValidationTrack: String, Codable, Hashable, Sendable {
    case manual, automated
    var title: String { self == .manual ? "수동 측정점" : "자동 측정점" }
}

/// Literal user-entered conditions are retained. Missing conditions stay unknown;
/// free-form text is never interpreted as a verified fabric, distance, or pose.
nonisolated struct MeasurementValidationGroupKey: Hashable, Codable, Sendable {
    var deviceModel: String?
    var categoryID: String?
    var specimenName: String?
    var conditions: String?
    var definitionID: String
    var definitionLandmarkIDs: [String]
    var track: MeasurementValidationTrack
    var depthSource: String
    var modelVersion: String?
    var optionsFingerprint: String

    var categoryTitle: String { categoryID.flatMap(GarmentCategory.init(rawValue:))?.title ?? "미기록" }
    var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(self)) ?? Data()).base64EncodedString()
    }
    var hasRepeatContext: Bool {
        deviceModel != nil && categoryID != nil && specimenName != nil && conditions != nil
    }
}

nonisolated struct MeasurementValidationSample: Sendable, Identifiable {
    var recordID: UUID
    var sessionID: UUID
    var frameID: UUID
    var savedAt: Date
    var capturedAt: Date
    var definitionID: String
    var title: String
    var origin: LandmarkOrigin
    var modelVersion: String?
    var context: MeasurementTestContext?
    var source: DepthSource
    var referenceCentimeters: Double?
    var value: MeasurementValue
    var groupKey: MeasurementValidationGroupKey
    fileprivate var frameIdentity: MeasurementValidationFrameIdentity
    fileprivate var landmarkIDs: [String]

    var id: String { "\(sessionID)/\(frameID)/\(definitionID)/\(origin.rawValue)" }
    var frameKey: String { "\(sessionID)/\(frameID)" }
    fileprivate var pairKey: String { "\(frameKey)/\(definitionID)" }
    var centimeters: Double? {
        guard value.status != .unavailable, let meters = value.meters, meters.isFinite, meters > 0 else { return nil }
        return meters * 100
    }
    var errorCentimeters: Double? {
        guard let centimeters, let referenceCentimeters else { return nil }
        return centimeters - referenceCentimeters
    }
}

nonisolated struct MeasurementValidationStatistics: Sendable {
    var attempts: Int
    var valid: Int
    var uncertain: Int
    var unavailable: Int
    var referencedAttempts: Int
    var compared: Int
    var meanAbsoluteErrorCentimeters: Double?
    var percentile95AbsoluteErrorCentimeters: Double?
    var meanSignedErrorCentimeters: Double?
    var numericResults: Int
    var numericResultRate: Double? { attempts == 0 ? nil : Double(numericResults) / Double(attempts) }
    var qualityAcceptedRate: Double? { attempts == 0 ? nil : Double(valid) / Double(attempts) }

    init(samples: [MeasurementValidationSample]) {
        attempts = samples.count
        valid = samples.filter { $0.value.status == .valid }.count
        uncertain = samples.filter { $0.value.status == .uncertain }.count
        unavailable = samples.filter { $0.value.status == .unavailable }.count
        numericResults = samples.filter { $0.centimeters != nil }.count
        referencedAttempts = samples.filter { $0.referenceCentimeters != nil }.count
        let errors = samples.compactMap(\.errorCentimeters)
        compared = errors.count
        if errors.isEmpty {
            meanAbsoluteErrorCentimeters = nil
            percentile95AbsoluteErrorCentimeters = nil
            meanSignedErrorCentimeters = nil
        } else {
            let absolute = errors.map(abs).sorted()
            meanAbsoluteErrorCentimeters = absolute.reduce(0, +) / Double(errors.count)
            percentile95AbsoluteErrorCentimeters = absolute[Int(ceil(Double(errors.count) * 0.95)) - 1]
            meanSignedErrorCentimeters = errors.reduce(0, +) / Double(errors.count)
        }
    }
}

nonisolated enum MeasurementValidationAssessment: String, Sendable {
    case awaitingReference, insufficientSamples, outsideProposedThresholds, requiresHumanReview
    var title: String {
        switch self {
        case .awaitingReference: "줄자 비교 대기"
        case .insufficientSamples: "표본 부족 · 검증 중"
        case .outsideProposedThresholds: "제안 기준 미달 · 개선 필요"
        case .requiresHumanReview: "제안 수치 충족 · 인수 검토 필요"
        }
    }
}

nonisolated struct MeasurementValidationGroup: Sendable, Identifiable {
    var key: MeasurementValidationGroupKey
    var title: String
    var statistics: MeasurementValidationStatistics
    var repetitionCount: Int
    var repeatedMeasurementRangeCentimeters: Double?
    var repeatedMeasurementStandardDeviationCentimeters: Double?
    var id: String { key.id }
    var assessment: MeasurementValidationAssessment {
        guard statistics.compared > 0 else { return .awaitingReference }
        guard statistics.compared >= MeasurementValidationCriteria.minimumComparedSamples else { return .insufficientSamples }
        guard let mae = statistics.meanAbsoluteErrorCentimeters,
              let p95 = statistics.percentile95AbsoluteErrorCentimeters,
              let rate = statistics.numericResultRate,
              mae <= MeasurementValidationCriteria.maximumMeanAbsoluteErrorCentimeters,
              p95 <= MeasurementValidationCriteria.maximumP95AbsoluteErrorCentimeters,
              rate >= MeasurementValidationCriteria.minimumNumericResultRate else { return .outsideProposedThresholds }
        return .requiresHumanReview
    }

    fileprivate init(key: MeasurementValidationGroupKey, samples: [MeasurementValidationSample]) {
        self.key = key
        title = samples.first?.title ?? key.definitionID
        statistics = .init(samples: samples)
        let values = samples.compactMap(\.centimeters)
        // One row per frame/definition/origin has already been enforced. Re-saving a
        // frame cannot create another repetition. Unknown specimens cannot be pooled.
        repetitionCount = key.hasRepeatContext ? values.count : 0
        if key.hasRepeatContext, values.count >= 2 {
            let mean = values.reduce(0, +) / Double(values.count)
            repeatedMeasurementRangeCentimeters = values.max()! - values.min()!
            repeatedMeasurementStandardDeviationCentimeters = sqrt(
                values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1))
        } else {
            repeatedMeasurementRangeCentimeters = nil
            repeatedMeasurementStandardDeviationCentimeters = nil
        }
    }
}

nonisolated enum MeasurementValidationPairStatus: String, Sendable {
    case comparable, unavailable, mismatchedInput
}

/// Automatic-minus-manual is disagreement, not an error against physical truth.
nonisolated struct MeasurementValidationPair: Sendable, Identifiable {
    var id: String
    var manualSampleID: String
    var automatedSampleID: String
    var status: MeasurementValidationPairStatus
    var differenceCentimeters: Double?
    var manualTruthErrorCentimeters: Double?
    var automatedTruthErrorCentimeters: Double?
    var sharedReferenceCentimeters: Double?
    var absoluteDifferenceCentimeters: Double? { differenceCentimeters.map(abs) }
}

nonisolated struct MeasurementValidationCounts: Sendable {
    var recordsSeen: Int
    var includedSamples: Int
    var manualSamples: Int
    var automatedSamples: Int
    var syntheticRecords: Int
    var modelMetadataMissingRecords: Int
    var malformedRecords: Int
    var duplicateSamples: Int
    var pairedComparisons: Int
    var pairedUnavailable: Int
    var pairMismatches: Int
    var automatedWithoutManual: Int
}

nonisolated struct MeasurementValidationReport: Sendable {
    var samples: [MeasurementValidationSample]
    var groups: [MeasurementValidationGroup]
    var pairs: [MeasurementValidationPair]
    var counts: MeasurementValidationCounts
    var algorithmVersion: String
    var manual: MeasurementValidationStatistics { .init(samples: samples.filter { $0.origin == .manual }) }
    var automated: MeasurementValidationStatistics { .init(samples: samples.filter { $0.origin == .model }) }
    var statusSummary: String {
        guard !samples.isEmpty else { return "실측 기록 없음 · 검증 대기" }
        let count = manual.compared + automated.compared
        guard count > 0 else { return "줄자 비교값 없음 · 정확도 검증 대기" }
        return "줄자 오차 비교 \(count)건 · 최종 인수 검토 필요"
    }

    /// One row per retained attempt, including failed and unreferenced attempts.
    var csv: String {
        let header = ["record_id", "session_id", "frame_id", "captured_at", "group_id", "origin", "model_version", "device", "category", "specimen", "conditions", "depth_source", "definition_id", "measurement", "reference_cm", "measured_cm", "status", "failure", "truth_error_cm", "algorithm_version", "saved_options", "pair_status", "automatic_minus_manual_cm", "pair_shared_reference_cm"]
        let formatter = ISO8601DateFormatter()
        let byAutomatedID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.automatedSampleID, $0) })
        let byManualID = Dictionary(uniqueKeysWithValues: pairs.map { ($0.manualSampleID, $0) })
        var rows = [header]
        for sample in samples {
            let key = sample.groupKey
            let pair = byAutomatedID[sample.id] ?? byManualID[sample.id]
            rows.append([
                sample.recordID.uuidString, sample.sessionID.uuidString, sample.frameID.uuidString,
                formatter.string(from: sample.capturedAt), key.id, sample.origin.rawValue,
                Self.safeCell(sample.modelVersion ?? ""), Self.safeCell(key.deviceModel ?? ""), key.categoryID ?? "",
                Self.safeCell(key.specimenName ?? ""), Self.safeCell(key.conditions ?? ""), sample.source.rawValue,
                Self.safeCell(sample.definitionID), Self.safeCell(sample.title), Self.number(sample.referenceCentimeters),
                Self.number(sample.centimeters), sample.value.status.rawValue, sample.value.failure?.rawValue ?? "",
                Self.number(sample.errorCentimeters), algorithmVersion, key.optionsFingerprint,
                pair?.status.rawValue ?? "", Self.number(pair?.differenceCentimeters), Self.number(pair?.sharedReferenceCentimeters)
            ])
        }
        return "\u{FEFF}" + rows.map { row in
            row.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    var markdown: String {
        var lines = ["# LiDAR 측정 검증 보고서", "", statusSummary, "",
            "저장된 측정점과 촬영 데이터를 현재 거리 엔진으로 다시 계산했습니다. 저장된 결과 수치를 재사용하거나 옵션을 임의로 바꾸지 않았습니다. 자동 측정점 평가는 저장된 모델 버전·측정점의 재계산이며 모델 재추론은 아닙니다.", "",
            "- 수동 측정점: \(manual.attempts)회 · 수치 \(manual.numericResults)회 · 확인 필요 \(manual.uncertain)회 · 실패 \(manual.unavailable)회 · 줄자 오차 비교 \(manual.compared)회",
            "- 자동 측정점: \(automated.attempts)회 · 수치 \(automated.numericResults)회 · 확인 필요 \(automated.uncertain)회 · 실패 \(automated.unavailable)회 · 줄자 오차 비교 \(automated.compared)회",
            "- 제외: 합성 \(counts.syntheticRecords)건 · 모델 버전 누락 \(counts.modelMetadataMissingRecords)건 · 읽기/형식 오류 \(counts.malformedRecords)건 · 중복 항목 \(counts.duplicateSamples)건", "",
            "## 조건별 결과", "", MeasurementValidationCriteria.description, "",
            "| 기기 / 종류 / 물체 / 조건 | 측정점 / 모델 / 깊이 | 항목 | 수치/시도 | 품질 충족/확인 필요/실패 | 줄자 비교/기준값 | MAE / P95 / 편향(cm) | 반복 수 / 범위 / 표본 표준편차(cm) | 검토 상태 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for group in groups {
            let key = group.key, stats = group.statistics
            let context = [key.deviceModel ?? "미기록", key.categoryTitle, key.specimenName ?? "미기록", key.conditions ?? "미기록"].map(Self.markdownCell).joined(separator: " / ")
            let method = [key.track.title, key.modelVersion ?? "—", key.depthSource].map(Self.markdownCell).joined(separator: " / ")
            lines.append("| \(context) | \(method) | \(Self.markdownCell(group.title)) | \(stats.numericResults)/\(stats.attempts) | \(stats.valid)/\(stats.uncertain)/\(stats.unavailable) | \(stats.compared)/\(stats.referencedAttempts) | \(Self.display(stats.meanAbsoluteErrorCentimeters)) / \(Self.display(stats.percentile95AbsoluteErrorCentimeters)) / \(Self.display(stats.meanSignedErrorCentimeters)) | \(group.repetitionCount) / \(Self.display(group.repeatedMeasurementRangeCentimeters)) / \(Self.display(group.repeatedMeasurementStandardDeviationCentimeters)) | \(group.assessment.title) |")
        }
        lines += ["", "실패는 전체 시도 수에 유지합니다. 오차는 유효한 줄자값과 측정값이 함께 있는 기록만 사용하며, ‘확인 필요’ 수치도 포함합니다. 같은 프레임·항목·측정점 출처의 중복 저장은 최신 편집 한 건만 사용합니다.", "",
            "반복 산포는 기기·옷 종류·물체 이름·촬영 조건이 모두 기록되고 같은 항목·옵션·깊이 출처·모델 버전인 별도 촬영끼리만 계산합니다. 조건은 입력 문구 그대로 묶으며 소재나 촬영 거리를 추정하지 않습니다. 그룹의 옵션 상세는 CSV의 saved_options에서 확인할 수 있습니다.", "",
            "## 같은 촬영의 자동·수동 측정점 비교", "",
            "비교 가능 \(counts.pairedComparisons)쌍 · 측정 실패 포함 \(counts.pairedUnavailable)쌍 · 입력 불일치 \(counts.pairMismatches)쌍 · 수동 대조 없음 \(counts.automatedWithoutManual)건.", "",
            "자동−수동 차이는 두 방식의 불일치이며 줄자 대비 오차가 아닙니다. 두 행은 동일 촬영에서 파생된 관측이므로 독립 촬영 두 번으로 해석하면 안 됩니다. 카메라·깊이 데이터·항목의 점 순서·저장 옵션이 같을 때만 편차를 계산합니다.", ""]
        if pairs.isEmpty {
            lines.append("비교할 자동·수동 측정점 쌍이 없습니다.")
        } else {
            lines += [
                "| 프레임(앞 8자리) | 항목 | 상태 | 자동−수동 편차(cm) | 수동 줄자오차(cm) | 자동 줄자오차(cm) | 공통 줄자값(cm) |",
                "| --- | --- | --- | --- | --- | --- | --- |"]
            let sampleByID = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0) })
            for pair in pairs {
                let sample = sampleByID[pair.automatedSampleID] ?? sampleByID[pair.manualSampleID]
                let frame = sample.map { String($0.frameID.uuidString.prefix(8)) } ?? "—"
                let title = sample.map { Self.markdownCell("\($0.title) (\($0.definitionID))") } ?? "—"
                let status: String
                switch pair.status {
                case .comparable: status = "비교 가능"
                case .unavailable: status = "측정 불가"
                case .mismatchedInput: status = "입력 불일치"
                }
                let comparable = pair.status == .comparable
                let difference = Self.display(comparable ? pair.differenceCentimeters : nil)
                let manualError = Self.display(comparable ? pair.manualTruthErrorCentimeters : nil)
                let automaticError = Self.display(comparable ? pair.automatedTruthErrorCentimeters : nil)
                let reference = comparable
                    ? pair.sharedReferenceCentimeters.map { Self.display($0) } ?? "공통 없음"
                    : "—"
                lines.append("| \(frame) | \(title) | \(status) | \(difference) | \(manualError) | \(automaticError) | \(reference) |")
            }
            lines += ["", "수동·자동 줄자오차는 각각 해당 기록에 입력된 줄자 기준값으로 계산합니다. 두 기준값이 다르거나 어느 한쪽에 없으면 공통 줄자값은 ‘공통 없음’입니다. 측정 불가·입력 불일치 쌍은 이 표에서 수치를 표시하지 않습니다."]
        }
        lines += ["",
            "품질 상태나 모델 신뢰도는 정확도 백분율이 아닙니다. 제안 기준 충족도 모든 옷·소재·환경에서의 정확도 보장을 뜻하지 않습니다.", "",
            "알고리즘: \(algorithmVersion)"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func safeCell(_ value: String) -> String {
        guard let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first, "=+-@".contains(first) else { return value }
        return "'" + value
    }
    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func display(_ value: Double?) -> String { value == nil ? "—" : number(value) }
    private static func markdownCell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// Retains lightweight replay results and frame digests, not every full depth/image buffer.
nonisolated struct MeasurementValidationReportBuilder {
    private var rows: [String: MeasurementValidationSample] = [:]
    private var latestEdits: [String: (savedAt: Date, recordID: UUID)] = [:]
    private var recordsSeen = 0, synthetic = 0, missingModelMetadata = 0, malformed = 0, duplicates = 0
    private var replayAlgorithmVersions = Set<String>()

    mutating func addUnreadableRecord() { recordsSeen += 1; malformed += 1 }

    mutating func add(_ record: SavedMeasurement) {
        recordsSeen += 1
        guard record.snapshot.frame.source != .synthetic, record.landmarks.origin != .synthetic else { synthetic += 1; return }
        let version = Self.nonempty(record.landmarks.modelVersion)
        // Corrected geometry is human-assisted evidence. It must not improve the
        // model-only accuracy track, even when untouched points remain model-backed.
        let reportedOrigin: LandmarkOrigin = record.landmarks.points.contains { $0.origin == .manual }
            ? .manual : record.landmarks.origin
        let frame = record.snapshot.frame
        guard !record.definitions.isEmpty, record.definitions.count <= 100,
              record.definitions.allSatisfy({ !$0.id.isEmpty }),
              Set(record.definitions.map(\.id)).count == record.definitions.count,
              record.landmarks.sessionID == frame.sessionID, record.landmarks.frameID == frame.frameID,
              frame.timestamp.isFinite, frame.capturedAt.timeIntervalSince1970.isFinite,
              record.savedAt.timeIntervalSince1970.isFinite else { malformed += 1; return }
        if record.landmarks.origin == .model, version == nil {
            missingModelMetadata += 1
            // An untraceable latest edit must not silently resurrect an older model result.
            for definition in record.definitions {
                if let key = keepLatest(record, definitionID: definition.id) { rows.removeValue(forKey: key) }
            }
            return
        }
        let output = MeasurementCalculator.measure(
            frame: frame, landmarks: record.landmarks, definitions: record.definitions, options: record.options)
        replayAlgorithmVersions.insert(output.algorithmVersion)
        guard output.values.count == record.definitions.count else { malformed += 1; return }
        let identity = MeasurementValidationFrameIdentity(record.snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let options = (try? encoder.encode(record.options)).flatMap { String(data: $0, encoding: .utf8) } ?? "invalid options"
        for (definition, value) in zip(record.definitions, output.values) {
            guard keepLatest(record, definitionID: definition.id) != nil else { continue }
            let reference: Double?
            if let byDefinition = record.referenceByDefinitionCentimeters {
                reference = byDefinition[definition.id]
            } else {
                // A legacy scalar reference cannot be assigned to every measurement of a garment.
                reference = record.definitions.count == 1 ? record.referenceCentimeters : nil
            }
            let key = MeasurementValidationGroupKey(
                deviceModel: Self.nonempty(record.testContext?.deviceModel), categoryID: record.testContext?.category.rawValue,
                specimenName: Self.nonempty(record.testContext?.specimenName), conditions: Self.nonempty(record.testContext?.conditions),
                definitionID: definition.id, definitionLandmarkIDs: definition.landmarkIDs,
                track: reportedOrigin == .manual ? .manual : .automated,
                depthSource: frame.source.rawValue, modelVersion: reportedOrigin == .model ? version : nil,
                optionsFingerprint: options)
            let sample = MeasurementValidationSample(recordID: record.id, sessionID: frame.sessionID, frameID: frame.frameID,
                savedAt: record.savedAt, capturedAt: frame.capturedAt, definitionID: definition.id, title: definition.title,
                origin: reportedOrigin, modelVersion: key.modelVersion, context: record.testContext, source: frame.source,
                referenceCentimeters: reference.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, value: value,
                groupKey: key, frameIdentity: identity, landmarkIDs: definition.landmarkIDs)
            rows[sample.id] = sample
        }
    }

    private mutating func keepLatest(_ record: SavedMeasurement, definitionID: String) -> String? {
        let frame = record.snapshot.frame
        let origin: LandmarkOrigin = record.landmarks.points.contains { $0.origin == .manual } ? .manual : record.landmarks.origin
        let key = "\(frame.sessionID)/\(frame.frameID)/\(definitionID)/\(origin.rawValue)"
        if let previous = latestEdits[key] {
            duplicates += 1
            if previous.savedAt > record.savedAt || (previous.savedAt == record.savedAt && previous.recordID.uuidString > record.id.uuidString) { return nil }
        }
        latestEdits[key] = (record.savedAt, record.id)
        return key
    }

    func report() -> MeasurementValidationReport {
        let samples = rows.values.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt
        }
        let groups = Dictionary(grouping: samples, by: \.groupKey).map { key, values in
            MeasurementValidationGroup(key: key, samples: values)
        }.sorted { $0.id < $1.id }
        let manual = Dictionary(uniqueKeysWithValues: samples.filter { $0.origin == .manual }.map { ($0.pairKey, $0) })
        let automated = samples.filter { $0.origin == .model }
        var pairs: [MeasurementValidationPair] = []
        for auto in automated {
            guard let hand = manual[auto.pairKey] else { continue }
            let inputsMatch = hand.frameIdentity == auto.frameIdentity && hand.landmarkIDs == auto.landmarkIDs
                && hand.groupKey.optionsFingerprint == auto.groupKey.optionsFingerprint
            let difference: Double?
            if inputsMatch, let a = auto.centimeters, let b = hand.centimeters { difference = a - b } else { difference = nil }
            pairs.append(.init(id: auto.pairKey, manualSampleID: hand.id, automatedSampleID: auto.id,
                status: !inputsMatch ? .mismatchedInput : difference == nil ? .unavailable : .comparable,
                differenceCentimeters: difference, manualTruthErrorCentimeters: hand.errorCentimeters,
                automatedTruthErrorCentimeters: auto.errorCentimeters,
                sharedReferenceCentimeters: hand.referenceCentimeters == auto.referenceCentimeters ? hand.referenceCentimeters : nil))
        }
        let counts = MeasurementValidationCounts(recordsSeen: recordsSeen, includedSamples: samples.count,
            manualSamples: manual.count, automatedSamples: automated.count, syntheticRecords: synthetic,
            modelMetadataMissingRecords: missingModelMetadata, malformedRecords: malformed, duplicateSamples: duplicates,
            pairedComparisons: pairs.filter { $0.status == .comparable }.count,
            pairedUnavailable: pairs.filter { $0.status == .unavailable }.count,
            pairMismatches: pairs.filter { $0.status == .mismatchedInput }.count,
            automatedWithoutManual: automated.count - pairs.count)
        let versions = replayAlgorithmVersions.sorted()
        let algorithm = versions.isEmpty ? LiDARMeasurementEngine.algorithmVersion : versions.joined(separator: " + ")
        return .init(samples: samples, groups: groups, pairs: pairs, counts: counts, algorithmVersion: algorithm)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// The ID alone is insufficient when imported records have changed calibration or depth.
/// A SHA-256 digest bounds retained memory while checking the complete depth/confidence data.
nonisolated fileprivate struct MeasurementValidationFrameIdentity: Equatable, Sendable {
    var sessionID: UUID
    var frameID: UUID
    var timestamp: TimeInterval
    var capturedAt: Date
    var imageSize: PixelSize
    var intrinsics: CameraIntrinsics
    var orientation: ImageOrientation
    var source: DepthSource
    var depthSize: PixelSize
    var confidencePresent: Bool
    var depthValuesCount: Int
    var confidenceCount: Int?
    var depthDigest: String
    var imageDigest: String

    init(_ snapshot: CaptureSnapshot) {
        let frame = snapshot.frame
        sessionID = frame.sessionID; frameID = frame.frameID; timestamp = frame.timestamp; capturedAt = frame.capturedAt
        imageSize = frame.imageSize; intrinsics = frame.intrinsics; orientation = frame.orientation; source = frame.source
        depthSize = frame.depth.size; confidencePresent = frame.depth.confidence != nil
        depthValuesCount = frame.depth.values.count; confidenceCount = frame.depth.confidence?.count
        var hash = SHA256()
        frame.depth.values.withUnsafeBytes { hash.update(data: Data($0)) }
        if let confidence = frame.depth.confidence { hash.update(data: Data(confidence)) }
        depthDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        imageDigest = SHA256.hash(data: snapshot.imageJPEG).map { String(format: "%02x", $0) }.joined()
    }
}
