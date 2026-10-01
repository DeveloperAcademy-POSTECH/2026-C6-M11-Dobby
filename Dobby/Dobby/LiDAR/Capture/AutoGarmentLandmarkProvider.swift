import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

nonisolated enum AutoGarmentRecognitionError: Error, LocalizedError, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying {
    case noDetection, ambiguous, unsupported, invalidProvenance
    case missingClassifier, incompatibleClassifier

    var errorDescription: String? {
        switch self {
        case .noDetection: "옷 종류를 인식하지 못했습니다. 상의나 바지 한 벌을 평평하게 펼쳐 주세요."
        case .ambiguous: "상의와 하의를 구분하기 어렵습니다. 소매와 바짓단이 모두 보이도록 펼쳐 주세요."
        case .unsupported: "이 옷의 자동 실측은 아직 지원하지 않습니다. 상의·바지·반바지를 촬영해 주세요."
        case .invalidProvenance: "인식한 옷 종류와 측정 모델이 일치하지 않습니다. 다시 촬영해 주세요."
        case .missingClassifier: "옷 종류 분류 모델이 앱에 포함되지 않았습니다."
        case .incompatibleClassifier: "옷 종류 분류 모델의 형식이 맞지 않습니다."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .invalidProvenance, .missingClassifier, .incompatibleClassifier: .invalidConfiguration
        default: .providerFailure
        }
    }
}

nonisolated struct AutoGarmentClassificationAttempt: Codable, Sendable {
    var orientation: ImageOrientation
    var scores: [GarmentClassificationScore]
    var route: GarmentClassifierRoute
    var evidence: GarmentKindEvidence?
    var poseError: String?
}

/// Scores belong only to the supplied classifier. They are never compared with
/// pose detector scores or represented as calibrated accuracy probabilities.
nonisolated struct AutoGarmentRecognitionEvaluation: Sendable {
    var decision: GarmentKindSelection
    var top: GarmentKindEvidence?
    var bottoms: GarmentKindEvidence?
    var recognition: GarmentForegroundRecognition?
    var classificationAttempts: [AutoGarmentClassificationAttempt]
    var isUnsupported: Bool
    var poseRequests: Int?
    var foregroundRequests: Int?
}

/// The supplied fifteen-category classifier routes this exact RGB frame to one
/// cached pose model. That model independently associates its points with a
/// foreground mask. No live result or mutable last kind is reused for capture.
actor AutoGarmentLandmarkProvider: GarmentMeasurementDefinitionProviding, GarmentImageRecognizing {
    private nonisolated let top: CoreMLGarmentLandmarkProvider
    private nonisolated let bottoms: CoreMLGarmentLandmarkProvider
    private let classifierURL: URL
    private var classifier: VNCoreMLModel?
    private let foreground = GarmentForegroundMaskAnalyzer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var hasPrepared = false

    // Rejection heuristics for this uncalibrated classifier. A passing category
    // must still have independent pose and silhouette evidence on the same RGB.
    private static let minimumClassScore = 0.10
    private static let minimumCrossKindMargin = 0.01

    init(top: CoreMLGarmentLandmarkProvider, bottoms: CoreMLGarmentLandmarkProvider,
         classifierModelURL: URL) throws {
        guard top.kind == .top, bottoms.kind == .bottoms else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        self.top = top
        self.bottoms = bottoms
        self.classifierURL = classifierModelURL
    }

    nonisolated static func bundled(in bundle: Bundle = .main) throws -> AutoGarmentLandmarkProvider {
        guard let classifier = bundle.url(forResource: "clothes_image_detection", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "clothes_image_detection", withExtension: "mlpackage") else {
            throw AutoGarmentRecognitionError.missingClassifier
        }
        return try .init(top: CoreMLGarmentLandmarkProvider.bundled(kind: .top, in: bundle),
                         bottoms: CoreMLGarmentLandmarkProvider.bundled(kind: .bottoms, in: bundle),
                         classifierModelURL: classifier)
    }

    func prepare() async throws {
        guard !hasPrepared else { return }
        try await top.preparePoseModel()
        try await bottoms.preparePoseModel()
        try Task.checkCancellation()
        let neutral = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        guard let image = context.createCGImage(neutral, from: neutral.extent) else {
            throw BottomModelError.bufferCreation
        }
        _ = try classify(image, orientation: .up)
        do { _ = try foreground.masks(for: image) }
        catch GarmentMaskAssociationError.noForeground {}
        try Task.checkCancellation()
        hasPrepared = true
    }

    nonisolated func measurementDefinitions(for landmarks: GarmentLandmarkSet) throws -> [MeasurementDefinition] {
        guard landmarks.origin == .model, let kind = landmarks.garmentKind else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        let provider = kind == .top ? top : bottoms
        let identifiers = Set(landmarks.points.map(\.id))
        let known = Set(provider.schema.keypoints + provider.schema.derivedOrder)
        guard landmarks.modelVersion == provider.modelVersion,
              !identifiers.isEmpty,
              identifiers.count == landmarks.points.count,
              identifiers.isSubset(of: known) else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        return provider.measurementDefinitions
    }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        let image = try rawImage(snapshot.imageJPEG)
        guard image.width == snapshot.frame.imageSize.width, image.height == snapshot.frame.imageSize.height else {
            throw BottomModelError.imageSizeMismatch
        }
        let result = try await recognizeForeground(image, orientation: snapshot.frame.orientation)
        try Task.checkCancellation()
        let landmarks = GarmentLandmarkSet(sessionID: snapshot.frame.sessionID,
            frameID: snapshot.frame.frameID, origin: .model,
            modelVersion: result.recognition.modelVersion, points: result.recognition.points,
            mask: result.selection.mask, garmentKind: result.recognition.garmentKind)
        _ = try measurementDefinitions(for: landmarks)
        return landmarks
    }

    func recognizeImage(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentImageRecognition {
        try await recognizeForeground(image, orientation: orientation).recognition
    }

    func recognizeForeground(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        let evaluation = try await evaluateImage(image, orientation: orientation)
        switch evaluation.decision {
        case .selected(let kind):
            guard let result = evaluation.recognition,
                  result.recognition.garmentKind == kind,
                  result.recognition.modelVersion == kind.modelVersion else {
                throw AutoGarmentRecognitionError.invalidProvenance
            }
            return result
        case .ambiguous: throw AutoGarmentRecognitionError.ambiguous
        case .noDetection:
            throw evaluation.isUnsupported ? AutoGarmentRecognitionError.unsupported : AutoGarmentRecognitionError.noDetection
        }
    }

    /// Each attempt is self-contained: classifier -> selected pose -> independent
    /// foreground -> structural compatibility. Recovery never compares category
    /// scores across rotations or substitutes the other model after an error.
    func evaluateImage(_ image: CGImage, orientation: ImageOrientation) async throws -> AutoGarmentRecognitionEvaluation {
        try Task.checkCancellation()
        let size = PixelSize(width: image.width, height: image.height)
        guard size.isValid else { throw BottomModelError.invalidImage }
        var attempts: [AutoGarmentClassificationAttempt] = []
        var topEvidence: GarmentKindEvidence?, bottomEvidence: GarmentKindEvidence?
        var hadUncertainty = false
        var poseRequests: Int? = 0, foregroundRequests: Int? = 0
        for direction in [orientation, GarmentPoseOrientationRecovery.halfTurn(of: orientation)] {
            try Task.checkCancellation()
            let scores = try classify(image, orientation: direction)
            let route = GarmentClassifierRoutingPolicy.route(scores: scores,
                minimumConfidence: Self.minimumClassScore, minimumCrossKindMargin: Self.minimumCrossKindMargin)
            var attempt = AutoGarmentClassificationAttempt(orientation: direction, scores: scores, route: route)
            switch route {
            case .unsupported:
                attempts.append(attempt)
                continue
            case .uncertain(let reason):
                if reason == .malformedResults || reason == .invalidConfiguration {
                    throw AutoGarmentRecognitionError.incompatibleClassifier
                }
                if reason == .ambiguousKinds || reason == .insufficientMargin { hadUncertainty = true }
                attempts.append(attempt)
                continue
            case .selected(let kind, _, _):
                let provider = kind == .top ? top : bottoms
                let result: GarmentForegroundRecognition
                do {
                    result = try await provider.recognizeForeground(image, orientation: direction)
                    try Task.checkCancellation()
                    if let count = poseRequests { poseRequests = count + result.poseRequests }
                    if let count = foregroundRequests { foregroundRequests = count + result.foregroundRequests }
                } catch GarmentModelError.noDetection {
                    attempt.evidence = .unmatched(kind: kind)
                    attempt.poseError = "noDetection"
                    if kind == .top { topEvidence = attempt.evidence } else { bottomEvidence = attempt.evidence }
                    poseRequests = nil; foregroundRequests = nil
                    attempts.append(attempt)
                    continue
                } catch GarmentMaskAssociationError.unmatchedGarment {
                    attempt.evidence = .unmatched(kind: kind)
                    attempt.poseError = "unmatchedForeground"
                    if kind == .top { topEvidence = attempt.evidence } else { bottomEvidence = attempt.evidence }
                    poseRequests = nil; foregroundRequests = nil
                    attempts.append(attempt)
                    continue
                } catch GarmentMaskAssociationError.noForeground {
                    attempt.evidence = .unmatched(kind: kind)
                    attempt.poseError = "noForeground"
                    if kind == .top { topEvidence = attempt.evidence } else { bottomEvidence = attempt.evidence }
                    poseRequests = nil; foregroundRequests = nil
                    attempts.append(attempt)
                    continue
                }
                // Multiple garments/foregrounds, cancellation and configuration
                // errors propagate. A second orientation cannot hide clutter.
                let evidence = GarmentKindSelectionPolicy.evaluate(kind: kind, points: result.recognition.points,
                                                                   selection: result.selection, imageSize: size)
                attempt.evidence = evidence
                attempts.append(attempt)
                if kind == .top { topEvidence = evidence } else { bottomEvidence = evidence }
                switch evidence.status {
                case .supported:
                    return .init(decision: .selected(kind), top: topEvidence, bottoms: bottomEvidence,
                                 recognition: result, classificationAttempts: attempts, isUnsupported: false,
                                 poseRequests: poseRequests, foregroundRequests: foregroundRequests)
                case .uncertain: hadUncertainty = true
                case .rejected: break
                }
            }
        }
        let unsupported = attempts.allSatisfy { if case .unsupported = $0.route { return true }; return false }
        return .init(decision: hadUncertainty ? .ambiguous : .noDetection,
                     top: topEvidence, bottoms: bottomEvidence, recognition: nil,
                     classificationAttempts: attempts, isUnsupported: unsupported,
                     poseRequests: poseRequests, foregroundRequests: foregroundRequests)
    }

    private func classify(_ image: CGImage, orientation: ImageOrientation) throws -> [GarmentClassificationScore] {
        try Task.checkCancellation()
        let request = VNCoreMLRequest(model: try loadedClassifier())
        request.imageCropAndScaleOption = .scaleFill
        let exif: CGImagePropertyOrientation
        switch orientation {
        case .up: exif = .up
        case .right: exif = .right
        case .down: exif = .down
        case .left: exif = .left
        }
        try VNImageRequestHandler(cgImage: image, orientation: exif, options: [:]).perform([request])
        try Task.checkCancellation()
        guard let results = request.results as? [VNClassificationObservation],
              results.count == GarmentClassificationCategory.allCases.count,
              Set(results.map(\.identifier)) == Set(GarmentClassificationCategory.allCases.map(\.rawValue)) else {
            throw AutoGarmentRecognitionError.incompatibleClassifier
        }
        return results.sorted { $0.confidence > $1.confidence }.map {
            .init(label: $0.identifier, confidence: Double($0.confidence))
        }
    }

    private func loadedClassifier() throws -> VNCoreMLModel {
        if let classifier { return classifier }
        try Task.checkCancellation()
        let url = classifierURL.pathExtension == "mlmodelc" ? classifierURL : try MLModel.compileModel(at: classifierURL)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName.count == 1,
              model.modelDescription.inputDescriptionsByName.values.first?.imageConstraint != nil else {
            throw AutoGarmentRecognitionError.incompatibleClassifier
        }
        let loaded = try VNCoreMLModel(for: model)
        try Task.checkCancellation()
        classifier = loaded
        return loaded
    }

    private func rawImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384 else {
            throw BottomModelError.invalidImage
        }
        return image
    }
}
