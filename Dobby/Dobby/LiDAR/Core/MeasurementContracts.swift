import Foundation

nonisolated struct PixelSize: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var isValid: Bool { width > 0 && height > 0 && width <= 16_384 && height <= 16_384 }
}

/// Original, unrotated RGB image coordinates. Origin at top left, x right, y down.
nonisolated struct ImagePoint: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var isValid: Bool { x.isFinite && y.isFinite && x >= 0 && x < 1 && y >= 0 && y < 1 }
}

nonisolated struct Point3D: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var z: Double
}

nonisolated struct CameraIntrinsics: Codable, Sendable, Equatable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var referenceSize: PixelSize
}

nonisolated enum ImageOrientation: String, Codable, Sendable, CaseIterable {
    case up, right, down, left
}

nonisolated enum DepthSource: String, Codable, Sendable {
    case sceneDepth, smoothedSceneDepth, synthetic
}

/// Rectified axial depth in metres, registered to the complete RGB image.
/// Invalid samples are zero. Missing confidence is unknown, never implicitly high.
nonisolated struct DepthMap: Codable, Sendable {
    var size: PixelSize
    var values: [Float]
    var confidence: [UInt8]?
}

nonisolated struct MeasurementFrame: Codable, Sendable {
    var sessionID: UUID
    var frameID: UUID
    var timestamp: TimeInterval
    var capturedAt: Date
    var imageSize: PixelSize
    var intrinsics: CameraIntrinsics
    var depth: DepthMap
    var source: DepthSource
    var orientation: ImageOrientation
}

/// RGB bytes and geometry must be captured atomically from the same source frame.
nonisolated struct CaptureSnapshot: Codable, Sendable {
    var frame: MeasurementFrame
    var imageJPEG: Data
    /// Optional comparison output from the very same ARFrame. The primary
    /// measurement continues to use raw sceneDepth; smoothing is not assumed
    /// to improve physical accuracy. Older archives omit both optional fields.
    var smoothedFrame: MeasurementFrame? = nil
    var selectionSummary: CaptureSelectionSummary? = nil
}

nonisolated enum LandmarkOrigin: String, Codable, Sendable {
    case manual, model, synthetic
}

nonisolated struct GarmentLandmark: Codable, Sendable, Identifiable {
    var id: String
    var point: ImagePoint
    var confidence: Double?
    var isVisible: Bool = true
    /// Source IDs whose resolved 3D positions are averaged; `point` is only a display hint.
    /// Nil means a direct point, except for the documented legacy model migration.
    /// Empty or invalid derivations must fail.
    var derivedFrom: [String]? = nil
    /// Nil inherits the set's provenance. A manually adjusted direct point, or
    /// a derivation affected by it, must not claim model confidence at its new
    /// coordinate. Unchanged points retain the original model checks.
    var origin: LandmarkOrigin? = nil
}

nonisolated struct GarmentMask: Codable, Sendable, Equatable {
    var size: PixelSize
    /// Registered to the complete original image. 0 = background, 1 = garment.
    var values: [UInt8]
}

nonisolated struct GarmentLandmarkSet: Codable, Sendable {
    var sessionID: UUID
    var frameID: UUID
    var origin: LandmarkOrigin
    var modelVersion: String?
    var points: [GarmentLandmark]
    var mask: GarmentMask?
    /// Selected from this exact RGB frame, never copied from a live preview.
    /// Optional preserves older archives and non-classifying adapters.
    var garmentKind: AutomaticGarmentKind? = nil
}

nonisolated struct MeasurementDefinition: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    /// Explicit straight segments, in order. No inferred surface length.
    var landmarkIDs: [String]
    /// Nil retains the existing straight-segment contract, including older archives.
    /// A projection removes the component parallel to an independently resolved 3D axis.
    var projection: MeasurementProjection? = nil
    static let testDistance = MeasurementDefinition(id: "test", title: "두 점 사이", landmarkIDs: ["A", "B"])
    static let longSleeve: [MeasurementDefinition] = [
        .init(id: "chest", title: "가슴 단면", landmarkIDs: ["armpitLeft", "armpitRight"]),
        .init(id: "shoulder", title: "어깨너비", landmarkIDs: ["shoulderLeft", "shoulderRight"]),
        .init(id: "length", title: "총장", landmarkIDs: ["neckSide", "hemBelowNeck"]),
        .init(id: "sleeve", title: "소매길이", landmarkIDs: ["shoulderLeft", "cuffLeft"])
    ]
}

nonisolated struct MeasurementProjection: Codable, Sendable, Equatable {
    /// Exactly two distinct physical landmark IDs; camera axes are not garment axes.
    var referenceAxisLandmarkIDs: [String]
}

nonisolated enum MeasurementStatus: String, Codable, Sendable {
    case valid, uncertain, unavailable
}

nonisolated enum MeasurementFailure: String, Error, Codable, Sendable {
    case frameMismatch, invalidCalibration, invalidDepthMap, invalidMask, invalidOptions
    case invalidDefinition, duplicateLandmark, missingLandmark, outOfBounds
    case insufficientDepth, lowLandmarkConfidence, occludedLandmark
}

nonisolated enum DepthSamplingMethod: String, Codable, Sendable {
    case localPlane, robustMedian, spatialAverage, axisProjection
}

nonisolated struct PointQuality: Codable, Sendable {
    var validSamples: Int
    var candidateSamples: Int
    var confidenceAvailable: Bool
    var depthSpreadMeters: Double
    var planeResidualMeters: Double?
    var method: DepthSamplingMethod
}

nonisolated struct ResolvedLandmark: Codable, Sendable {
    var id: String
    var imagePoint: ImagePoint
    var position: Point3D
    var quality: PointQuality
    /// Immediate contributors to a spatially derived point, absent for direct depth samples.
    var sourceLandmarkIDs: [String]? = nil
}

nonisolated struct MeasurementValue: Codable, Sendable, Identifiable {
    var id: String
    var title: String
    var meters: Double?
    var status: MeasurementStatus
    var failure: MeasurementFailure?
    var points: [ResolvedLandmark]
}

nonisolated struct GarmentMeasurementResult: Codable, Sendable {
    var sessionID: UUID
    var frameID: UUID
    var algorithmVersion: String
    var source: DepthSource
    var values: [MeasurementValue]
}

nonisolated struct MeasurementOptions: Codable, Sendable {
    var sampleRadius = 3
    var minimumSamples = 6
    var minimumDepthMeters = 0.15
    var maximumDepthMeters = 3.0
    var minimumSensorConfidence: UInt8 = 1
    var minimumModelConfidence = 0.5
    var maximumPlaneResidualMeters = 0.008
    var maximumDepthSpreadMeters = 0.025
    var useLocalPlane = true
}

/// Implemented by Ichi's model adapter. Return original-image coordinates and preserve IDs.
nonisolated protocol GarmentLandmarkProviding: Sendable {
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet
}

/// Resolve the measurement schema from the frozen inference result. A provider
/// must verify the result's kind and model version; mutable "last detected kind"
/// state would mix a later preview or cancelled run into this measurement.
nonisolated protocol GarmentMeasurementDefinitionProviding: GarmentLandmarkProviding {
    func measurementDefinitions(for landmarks: GarmentLandmarkSet) throws -> [MeasurementDefinition]
}
