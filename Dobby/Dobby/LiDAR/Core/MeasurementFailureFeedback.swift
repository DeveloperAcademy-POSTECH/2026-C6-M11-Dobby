import Foundation

/// These codes describe a guard that actually failed. They do not infer lighting,
/// distance, fabric, or user behaviour from an unavailable measurement.
nonisolated enum MeasurementFailureStage: String, Codable, Sendable {
    case input, landmark, depth, garmentPlane, contour, calculation, unknown
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

nonisolated enum MeasurementFailureReason: String, Codable, Sendable {
    case frameIdentityMismatch, invalidCalibration, malformedDepth, missingDepthConfidence, malformedConfidence
    case malformedMask, missingMask, maskCoverage, maskClipped, maskHasNoInterior, invalidOptions
    case missingPoint, hiddenPoint, pointOutsideImage, lowModelConfidence, duplicatePoint
    case invalidDefinition, dependencyCycle, dependencyLimit, invalidDerivation, duplicateDefinition
    case noDepthSamples, depthOutsideSupportedRange, lowSensorConfidence, tooFewDepthSamples
    case noSupportedDepthCluster, depthOutlierRejection, depthSupportTooFar, excessiveDepthSpread
    case planeTooFewSamples, planeLowValidFraction, planeInsufficientInliers, planeDegenerate
    case planeNarrowSupport, planeLowCoverage, planeHighResidual, planeViewingAngle, planeIntersectionRange
    case contourNeckAxisTooShort, contourDegenerateDirection, contourInvalidDirection
    case contourNoEntry, contourLeavesImage, contourEarlyExit, contourNoExit
    case invalidProjection, degenerateAxis, projectionOutsideImage, nonFiniteLength, zeroLength
    case missingResult, inconsistentResult, unknown
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

nonisolated enum MeasurementFailureScope: String, Codable, Sendable {
    case capture, measurement, landmark, unknown
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .unknown
    }
}

nonisolated enum MeasurementRecoveryAction: String, Codable, Sendable {
    case editPoints, correctTotalLength, retake, retry, none
    init(from decoder: Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .none
    }
}

nonisolated struct MeasurementFailureContext: Codable, Sendable, Equatable {
    var stage: MeasurementFailureStage
    var reason: MeasurementFailureReason
    var scope: MeasurementFailureScope = .measurement
    var affectedLandmarkIDs: [String] = []
    var recovery: MeasurementRecoveryAction = .retake
    /// Counts, limits or ratios measured at the failing guard, never estimates of physical accuracy.
    var evidence: [String: Double]? = nil

    func affecting(_ ids: [String]) -> Self {
        var result = self
        result.affectedLandmarkIDs = Array(Set(affectedLandmarkIDs + ids)).sorted()
        return result
    }

    private enum CodingKeys: String, CodingKey { case stage, reason, scope, affectedLandmarkIDs, recovery, evidence }
    init(stage: MeasurementFailureStage, reason: MeasurementFailureReason,
         scope: MeasurementFailureScope = .measurement, affectedLandmarkIDs: [String] = [],
         recovery: MeasurementRecoveryAction = .retake, evidence: [String: Double]? = nil) {
        self.stage = stage; self.reason = reason; self.scope = scope
        self.affectedLandmarkIDs = affectedLandmarkIDs; self.recovery = recovery
        self.evidence = evidence.map { $0.filter { $0.value.isFinite } }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        stage = try values.decodeIfPresent(MeasurementFailureStage.self, forKey: .stage) ?? .unknown
        reason = try values.decodeIfPresent(MeasurementFailureReason.self, forKey: .reason) ?? .unknown
        scope = try values.decodeIfPresent(MeasurementFailureScope.self, forKey: .scope) ?? .unknown
        affectedLandmarkIDs = try values.decodeIfPresent([String].self, forKey: .affectedLandmarkIDs) ?? []
        recovery = try values.decodeIfPresent(MeasurementRecoveryAction.self, forKey: .recovery) ?? .none
        evidence = try values.decodeIfPresent([String: Double].self, forKey: .evidence)
    }
}

/// Internal detailed errors are translated back to the original failure enum by
/// public geometry entry points. Existing callers keep their error contract.
nonisolated struct ContextualMeasurementError: Error {
    var failure: MeasurementFailure
    var context: MeasurementFailureContext
}

nonisolated struct MeasurementFailureFeedback: Sendable, Equatable {
    var reason: String
    var recovery: String
    var relatedLandmarkIDs: [String]
    var suggestedAction: MeasurementRecoveryAction
    var scope: MeasurementFailureScope
    var isCaptureFailure: Bool { scope == .capture }
}

nonisolated extension MeasurementValue {
    /// Quality advisories remain available for diagnostics, but do not turn an
    /// existing finite positive result into a user-facing failure.
    var hasUsableMeasurement: Bool {
        guard let meters else { return false }
        return meters.isFinite && meters > 0 && failure == nil && status != .unavailable
    }

    var failureFeedback: MeasurementFailureFeedback? {
        guard !hasUsableMeasurement else { return nil }
        let contexts = (failureContexts ?? []) + (pointFailures ?? []).compactMap(\.context)
        var reasons: [String] = []
        for context in contexts where context.reason != .unknown {
            let text = context.reason.explanation
            if !reasons.contains(text) { reasons.append(text) }
        }
        // Old point-level records can coexist with newly contextual failures.
        // Preserve every known failed contributor instead of showing only the first.
        for pointFailure in pointFailures ?? [] where pointFailure.context == nil || pointFailure.context?.reason == .unknown {
            let text = pointFailure.reason.fallbackExplanation
            if !reasons.contains(text) { reasons.append(text) }
        }
        if reasons.isEmpty { reasons = [failure?.fallbackExplanation ?? inconsistentResultExplanation] }
        let ids = Array(Set(contexts.flatMap(\.affectedLandmarkIDs)
            + (pointFailures ?? []).map(\.landmarkID))).sorted()
        let actions = contexts.map(\.recovery) + (pointFailures ?? []).filter { $0.context == nil }.map { $0.reason.fallbackRecovery }
        let action: MeasurementRecoveryAction
        if actions.contains(.retake) { action = .retake }
        else if actions.contains(.correctTotalLength) { action = .correctTotalLength }
        else if actions.contains(.editPoints) { action = .editPoints }
        else if actions.contains(.retry) { action = .retry }
        else { action = failure?.fallbackRecovery ?? .retry }
        return .init(reason: reasons.joined(separator: "\n"), recovery: action.instruction,
                     relatedLandmarkIDs: ids, suggestedAction: action,
                     scope: contexts.contains(where: { $0.scope == .capture }) ? .capture
                        : (contexts.first(where: { $0.scope != .unknown })?.scope ?? failure?.fallbackScope ?? .measurement))
    }

    private var inconsistentResultExplanation: String {
        guard let meters else { return "계산된 길이가 저장되지 않았어요. 이 기록에는 자세한 실패 원인이 없어요." }
        if !meters.isFinite { return "길이 계산 결과가 유한한 숫자가 아니에요." }
        if meters <= 0 { return "두 측정점 사이에서 양수인 길이를 계산하지 못했어요." }
        return "길이는 있지만 계산 실패 상태도 함께 기록되어 있어요. 이 기록에는 자세한 실패 원인이 없어요."
    }
}

nonisolated extension MeasurementRecoveryAction {
    var instruction: String {
        switch self {
        case .editPoints: "사진에서 해당 측정점을 확인하고 옷 위의 정확한 위치로 옮겨 주세요."
        case .correctTotalLength: "사진에서 총장 상단과 밑단을 직접 지정해 주세요."
        case .retake: "촬영 데이터를 새로 확보할 수 있도록 옷 전체가 보이게 다시 촬영해 주세요."
        case .retry: "다시 계산해 보고 같은 문제가 계속되면 다시 촬영해 주세요."
        case .none: "이 기록에는 복구 방법이 저장되어 있지 않아요. 다시 촬영해 주세요."
        }
    }
}

nonisolated extension MeasurementFailureReason {
    var explanation: String {
        switch self {
        case .frameIdentityMismatch: "사진과 측정점의 촬영 프레임이 달라요."
        case .invalidCalibration: "사진과 깊이를 연결하는 카메라 보정 정보가 유효하지 않아요."
        case .malformedDepth: "깊이 데이터의 크기나 형식이 사진과 맞지 않아요."
        case .missingDepthConfidence: "이번 촬영에 깊이 신뢰도 데이터가 없어 옷 평면을 계산하지 못했어요."
        case .malformedConfidence: "깊이 신뢰도 데이터의 크기나 값이 유효하지 않아요."
        case .malformedMask: "옷 윤곽 데이터의 크기나 형식이 유효하지 않아요."
        case .missingMask: "옷 윤곽을 얻지 못해 옷 평면을 계산하지 못했어요."
        case .maskCoverage: "사진에서 분리된 옷 윤곽의 면적이 평면 계산 범위를 벗어났어요."
        case .maskClipped: "옷 윤곽이 사진의 옆 가장자리에 닿아 있어요."
        case .maskHasNoInterior: "옷 윤곽 안에서 깊이를 수집할 내부 영역을 찾지 못했어요."
        case .invalidOptions: "길이 계산 설정이 지원 범위를 벗어났어요."
        case .missingPoint: "이 길이에 필요한 측정점을 찾지 못했어요."
        case .hiddenPoint: "필요한 측정점이 보이지 않는 상태로 인식됐어요."
        case .pointOutsideImage: "필요한 측정점의 좌표가 사진 범위를 벗어났어요."
        case .lowModelConfidence: "필요한 측정점의 인식 신뢰도가 계산 기준에 미치지 못했어요."
        case .duplicatePoint: "같은 이름의 측정점이 중복되어 사용할 점을 결정하지 못했어요."
        case .duplicateDefinition: "같은 측정 항목이 중복되어 계산할 항목을 결정하지 못했어요."
        case .invalidDefinition, .invalidDerivation: "이 항목의 측정점 연결 정보가 유효하지 않아요."
        case .dependencyCycle: "측정점 연결이 서로를 반복 참조해 위치를 계산하지 못했어요."
        case .dependencyLimit: "측정점 연결 단계가 계산 가능한 범위를 초과했어요."
        case .noDepthSamples: "측정점 주변에서 유효한 깊이값을 얻지 못했어요."
        case .depthOutsideSupportedRange: "측정점 주변 깊이값이 지원하는 깊이 범위에 들어오지 않아요."
        case .lowSensorConfidence: "수집한 깊이값의 센서 신뢰도가 계산 기준에 미치지 못했어요."
        case .tooFewDepthSamples: "측정점 주변에서 계산에 필요한 수만큼 깊이값을 모으지 못했어요."
        case .noSupportedDepthCluster: "주변 깊이값이 여러 표면으로 나뉘어 하나의 표면을 충분히 확인하지 못했어요."
        case .depthOutlierRejection: "튀는 깊이값을 제외한 뒤 계산에 필요한 깊이값이 부족해졌어요."
        case .depthSupportTooFar: "확인된 깊이값이 측정점에서 떨어져 있어 해당 점의 깊이로 쓸 수 없어요."
        case .excessiveDepthSpread: "주변 깊이값의 차이가 크고 이를 설명할 표면을 계산하지 못했어요."
        case .planeTooFewSamples: "옷 내부에서 평면 계산에 필요한 수만큼 깊이값을 얻지 못했어요."
        case .planeLowValidFraction: "옷 내부에서 계산 가능한 깊이값의 비율이 기준보다 낮아요."
        case .planeInsufficientInliers: "옷의 같은 평면에 속하는 깊이값을 충분히 찾지 못했어요."
        case .planeDegenerate: "깊이값으로 유효한 옷 평면을 구성하지 못했어요."
        case .planeNarrowSupport: "평면을 계산할 깊이값이 너무 좁거나 한 줄에 가깝게 모여 있어요."
        case .planeLowCoverage: "같은 평면으로 확인된 깊이값이 옷의 일부에만 모여 있어요."
        case .planeHighResidual: "옷의 깊이값과 계산된 평면의 차이가 허용 범위를 넘었어요."
        case .planeViewingAngle: "카메라 시선과 옷 평면의 각도가 계산 가능한 범위를 벗어났어요."
        case .planeIntersectionRange: "측정점과 옷 평면의 교점이 지원하는 깊이 범위를 벗어났어요."
        case .contourNeckAxisTooShort: "양쪽 목 기준점이 너무 가까워 총장 방향을 정하지 못했어요."
        case .contourDegenerateDirection, .contourInvalidDirection: "목 기준점과 밑단으로 총장 방향을 계산하지 못했어요."
        case .contourNoEntry: "밑단에서 총장 방향으로 이어지는 옷 내부를 찾지 못했어요."
        case .contourLeavesImage: "총장 상단을 찾는 선이 옷 윤곽과 만나기 전에 사진 밖으로 나갔어요."
        case .contourEarlyExit: "총장 방향의 선이 목 부근에 도달하기 전에 옷 윤곽 밖으로 나갔어요."
        case .contourNoExit: "총장 방향의 선에서 옷 상단 윤곽과 만나는 지점을 찾지 못했어요."
        case .invalidProjection: "이 항목의 투영 기준점 연결 정보가 유효하지 않아요."
        case .degenerateAxis: "기준축의 두 점이 겹치거나 너무 가까워 측정 방향을 정하지 못했어요."
        case .projectionOutsideImage: "계산된 측정점이 사진 범위를 벗어났어요."
        case .nonFiniteLength: "길이 계산 결과가 유한한 숫자가 아니에요."
        case .zeroLength: "두 측정점이 같은 위치여서 양수인 길이를 계산하지 못했어요."
        case .missingResult: "계산된 길이가 저장되지 않았어요."
        case .inconsistentResult: "계산 결과와 실패 상태가 일치하지 않아요."
        case .unknown: "이 기록에는 자세한 실패 원인이 저장되어 있지 않아요."
        }
    }
}

nonisolated extension MeasurementFailure {
    var fallbackExplanation: String {
        switch self {
        case .frameMismatch: "사진과 측정점의 촬영 프레임이 달라요."
        case .invalidCalibration: "카메라 보정 정보가 유효하지 않아요."
        case .invalidDepthMap: "깊이 데이터가 없거나 형식이 유효하지 않아요. 이 기록에는 세부 원인이 없어요."
        case .invalidMask: "옷 윤곽을 계산에 사용하지 못했어요. 이 기록에는 세부 원인이 없어요."
        case .invalidOptions: "길이 계산 설정이 유효하지 않아요."
        case .invalidDefinition: "측정점 연결이나 길이 계산을 완료하지 못했어요. 이 기록에는 세부 원인이 없어요."
        case .duplicateLandmark: "같은 이름의 측정점이 중복되어 있어요."
        case .missingLandmark: "이 길이에 필요한 측정점을 찾지 못했어요."
        case .outOfBounds: "필요한 측정점이 사진 범위를 벗어났어요."
        case .insufficientDepth: "필요한 깊이를 확보하지 못했어요. 이 기록에는 표본·신뢰도 등 세부 원인이 없어요."
        case .lowLandmarkConfidence: "필요한 측정점의 인식 신뢰도가 계산 기준에 미치지 못했어요."
        case .occludedLandmark: "필요한 측정점이 보이지 않는 상태로 인식됐어요."
        case .insufficientGarmentPlane: "옷 평면을 계산하지 못했어요. 이 기록에는 세부 원인이 없어요."
        case .contourIntersectionUnavailable: "총장 상단과 옷 윤곽의 교점을 찾지 못했어요. 이 기록에는 세부 원인이 없어요."
        }
    }
    var fallbackScope: MeasurementFailureScope {
        switch self {
        case .frameMismatch, .invalidCalibration, .invalidDepthMap, .invalidMask, .invalidOptions, .insufficientGarmentPlane: .capture
        default: .measurement
        }
    }
    var fallbackRecovery: MeasurementRecoveryAction {
        switch self {
        case .missingLandmark, .outOfBounds, .lowLandmarkConfidence, .occludedLandmark: .editPoints
        case .contourIntersectionUnavailable: .correctTotalLength
        case .duplicateLandmark, .invalidDefinition, .invalidOptions: .retry
        default: .retake
        }
    }
}

nonisolated extension MeasurementFailureContext {
    static func landmark(_ reason: MeasurementFailureReason, ids: [String],
                         recovery: MeasurementRecoveryAction? = nil) -> Self {
        let action: MeasurementRecoveryAction
        switch reason {
        case .duplicatePoint, .invalidDerivation, .dependencyCycle, .dependencyLimit: action = .retry
        case .invalidCalibration: action = .retake
        default: action = .editPoints
        }
        return .init(stage: .landmark, reason: reason, scope: .landmark,
                     affectedLandmarkIDs: ids, recovery: recovery ?? action)
    }
}

nonisolated extension MeasurementFailure {
    var landmarkFailureReason: MeasurementFailureReason {
        switch self {
        case .missingLandmark: .missingPoint
        case .duplicateLandmark: .duplicatePoint
        case .outOfBounds: .pointOutsideImage
        case .lowLandmarkConfidence: .lowModelConfidence
        case .occludedLandmark: .hiddenPoint
        case .invalidCalibration: .invalidCalibration
        case .invalidDefinition: .invalidDerivation
        default: .unknown
        }
    }
}
