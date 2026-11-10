import Foundation

nonisolated enum GarmentPlaneDiagnosticStage: String, Codable, Sendable {
    case input, mask, sampling, ransacSupport, initialRefit, refinementSupport, finalSupport
    case spatialSupport, coverage, residual, viewingAngle, accepted
    var title: String {
        switch self {
        case .input: "입력·보정값 검사"
        case .mask: "마스크 범위 검사"
        case .sampling: "깊이·신뢰도 표본 검사"
        case .ransacSupport: "첫 평면 후보의 일치 표본 수"
        case .initialRefit: "첫 평면 정밀 보정"
        case .refinementSupport: "보정 중 일치 표본 수"
        case .finalSupport: "최종 일치 표본 수"
        case .spatialSupport: "평면 표본의 공간 분포"
        case .coverage: "가로·세로 표본 범위"
        case .residual: "평면 잔차 검사"
        case .viewingAngle: "카메라와 평면의 각도"
        case .accepted: "평면 확정"
        }
    }
}

nonisolated enum GarmentPlaneSampleStatus: String, Codable, Sendable, CaseIterable {
    case inlier, outlier, invalidDepth, lowConfidence, candidate
    var title: String {
        switch self {
        case .inlier: "평면 일치"
        case .outlier: "평면 불일치"
        case .invalidDepth: "깊이 제외"
        case .lowConfidence: "신뢰도 제외"
        case .candidate: "후보·평면 없음"
        }
    }
}

nonisolated struct GarmentPlaneDiagnosticSample: Codable, Sendable, Identifiable {
    var id: Int
    /// Same unrotated RGB coordinates used by depth unprojection.
    var point: ImagePoint
    var depthMeters: Double?
    var sensorConfidence: UInt8?
    var status: GarmentPlaneSampleStatus
    /// Positive/negative is relative to the candidate normal, not floor height.
    var signedResidualMeters: Double? = nil
    var position: Point3D? = nil
}

nonisolated struct GarmentPlaneDiagnosticReport: Codable, Sendable {
    var schemaVersion = 1
    var algorithmVersion = GarmentPlaneGeometry.algorithmVersion
    var stage: GarmentPlaneDiagnosticStage
    var accepted: Bool
    var failure: MeasurementFailure?
    var context: MeasurementFailureContext?
    var candidateNormal: Point3D?
    var candidateOffset: Double?
    var quality: GarmentPlaneQuality?
    var samples: [GarmentPlaneDiagnosticSample]
    var toleranceMeters = GarmentPlaneGeometry.inlierToleranceMeters
    var minimumInlierFraction = GarmentPlaneGeometry.minimumInlierFraction
    var minimumSamples = GarmentPlaneGeometry.minimumSamples
    var candidateIterations: Int? = nil
    var initialInlierCount: Int? = nil
    var refinementProposals: [GarmentPlaneRefinementProposal]? = nil
    var samplingRegion: String? = nil

    var validCount: Int { samples.filter { $0.status == .inlier || $0.status == .outlier || $0.status == .candidate }.count }
    var inlierCount: Int { samples.filter { $0.status == .inlier }.count }
    var requiredCount: Int { max(minimumSamples, Int(ceil(Double(validCount) * minimumInlierFraction))) }
    var inlierFraction: Double? { candidateNormal != nil && validCount > 0 ? Double(inlierCount) / Double(validCount) : nil }
    func count(_ status: GarmentPlaneSampleStatus) -> Int { samples.filter { $0.status == status }.count }
}

nonisolated struct GarmentPlaneRefinementProposal: Codable, Sendable {
    var beforeInliers: Int
    var proposedInliers: Int
    var adopted: Bool
}

/// One synchronous fit owns this observer. It never changes fitting decisions,
/// sampling order, random seeds, thresholds or measurement outputs.
nonisolated final class GarmentPlaneDiagnosticTrace {
    var samplingRegion: String?
    var stage: GarmentPlaneDiagnosticStage = .input
    var samples: [GarmentPlaneDiagnosticSample] = []
    var normal: Point3D?
    var offset: Double?
    var candidateIterations = 0
    var initialInlierCount: Int?
    var refinementProposals: [GarmentPlaneRefinementProposal] = []

    func report(plane: GarmentPlane?, error: ContextualMeasurementError?) -> GarmentPlaneDiagnosticReport {
        var output = samples
        if let normal, let offset {
            for i in output.indices where output[i].status == .candidate {
                guard let position = output[i].position else { continue }
                let signed = GarmentPlaneGeometry.dot(normal, position) + offset
                output[i].signedResidualMeters = signed
                output[i].status = abs(signed) <= GarmentPlaneGeometry.inlierToleranceMeters ? .inlier : .outlier
            }
        }
        return .init(stage: stage, accepted: plane != nil, failure: error?.failure, context: error?.context,
            candidateNormal: normal, candidateOffset: offset, quality: plane?.quality, samples: output,
            candidateIterations: candidateIterations, initialInlierCount: initialInlierCount,
            refinementProposals: refinementProposals, samplingRegion: samplingRegion)
    }
}

nonisolated enum GarmentPlaneDiagnostics {
    static func analyze(frame: MeasurementFrame, mask: GarmentMask,
                        orientation: ImageOrientation, landmarks: GarmentLandmarkSet? = nil) -> GarmentPlaneDiagnosticReport {
        let trace = GarmentPlaneDiagnosticTrace()
        do {
            let plane = try GarmentPlaneGeometry.fitDetailed(frame: frame, mask: mask,
                uprightOrientation: orientation, landmarks: landmarks, diagnosticTrace: trace)
            return trace.report(plane: plane, error: nil)
        } catch let error as ContextualMeasurementError {
            return trace.report(plane: nil, error: error)
        } catch {
            return trace.report(plane: nil, error: .init(failure: .insufficientGarmentPlane,
                context: .init(stage: .garmentPlane, reason: .unknown, scope: .capture)))
        }
    }
}
