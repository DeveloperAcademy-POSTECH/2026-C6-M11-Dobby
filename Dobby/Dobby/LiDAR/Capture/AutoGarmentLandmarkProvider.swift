import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

nonisolated enum AutoGarmentRecognitionError: Error, LocalizedError, Sendable, Equatable,
    AutomaticMeasurementFailureClassifying {
    case noDetection, ambiguous, unsupported, invalidProvenance
    case missingClassifier, incompatibleClassifier
    case poseNotFound(AutomaticGarmentKind), foregroundNotFound
    case foregroundMismatch(AutomaticGarmentKind), shapeUnverified(AutomaticGarmentKind)

    var errorDescription: String? {
        switch self {
        case .noDetection: "촬영한 사진에서 옷 종류를 확실히 구분하지 못했어요. 옷과 구분되는 배경에서 한 벌 전체를 촬영하거나, 이 사진에서 점을 확인해 주세요."
        case .ambiguous: "상의와 하의를 구분하기 어렵습니다. 소매와 바짓단이 모두 보이도록 펼쳐 주세요."
        case .unsupported: "이 옷의 자동 실측은 아직 지원하지 않습니다. 상의·바지·반바지를 촬영해 주세요."
        case .invalidProvenance: "인식한 옷 종류와 측정 모델이 일치하지 않습니다. 다시 촬영해 주세요."
        case .missingClassifier: "옷 종류 분류 모델이 앱에 포함되지 않았습니다."
        case .incompatibleClassifier: "옷 종류 분류 모델의 형식이 맞지 않습니다."
        case .poseNotFound(let kind): "사진에서 \(kind.title)의 측정점을 찾지 못했어요. 소매나 바짓단까지 전체가 보이는지 확인하거나, 이 사진에서 점을 직접 지정해 주세요."
        case .foregroundNotFound: "사진에서 옷의 윤곽을 분리하지 못했어요. 옷과 구분되는 배경에서 촬영하거나, 이 사진에서 점을 확인해 주세요."
        case .foregroundMismatch(let kind): "\(kind.title)의 측정점과 사진 속 옷 윤곽이 충분히 일치하지 않아요. 옷과 구분되는 배경에서 촬영하거나, 이 사진에서 점을 확인해 주세요."
        case .shapeUnverified(let kind):
            kind == .top
                ? "상의의 몸통과 소매 구조를 확인하지 못했어요. 소매를 몸통에서 조금 떨어뜨려 펼치거나, 이 사진에서 점을 확인해 주세요."
                : "하의의 허리와 양쪽 다리 구조를 확인하지 못했어요. 두 바짓단 사이가 보이게 펼치거나, 이 사진에서 점을 확인해 주세요."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .invalidProvenance, .missingClassifier, .incompatibleClassifier: .invalidConfiguration
        default: .providerFailure
        }
    }

    var isRecognitionRejection: Bool { automaticMeasurementFailureCode != .invalidConfiguration }
}

nonisolated struct AutoGarmentClassificationAttempt: Codable, Sendable {
    var orientation: ImageOrientation
    var scores: [GarmentClassificationScore]
    var route: GarmentClassifierRoute
    var evidence: GarmentKindEvidence?
    var poseError: String?
    var poseAttempts: [GarmentPoseValidationAttempt]? = nil
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
    var orientationPrediction: GarmentOrientationPrediction? = nil
}

/// The supplied fifteen-category classifier routes this exact RGB frame to one
/// cached pose model. That model independently associates its points with a
/// foreground mask. A fresh-photo fallback never borrows another frame's points.
actor AutoGarmentLandmarkProvider: GarmentMeasurementDefinitionProviding, GarmentImageRecognizing {
    private nonisolated let top: CoreMLGarmentLandmarkProvider
    private nonisolated let bottoms: CoreMLGarmentLandmarkProvider
    private let orientationProvider: GarmentOrientationModelProvider
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
         classifierModelURL: URL, orientationModelURL: URL? = nil) throws {
        guard top.kind == .top, bottoms.kind == .bottoms else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        self.top = top
        self.bottoms = bottoms
        self.classifierURL = classifierModelURL
        self.orientationProvider = .init(modelURL: orientationModelURL
            ?? GarmentOrientationModelProvider.siblingURL(of: classifierModelURL))
    }

    nonisolated static func bundled(in bundle: Bundle = .main) throws -> AutoGarmentLandmarkProvider {
        guard let classifier = bundle.url(forResource: "clothes_image_detection", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "clothes_image_detection", withExtension: "mlpackage") else {
            throw AutoGarmentRecognitionError.missingClassifier
        }
        return try .init(top: CoreMLGarmentLandmarkProvider.bundled(kind: .top, in: bundle),
                         bottoms: CoreMLGarmentLandmarkProvider.bundled(kind: .bottoms, in: bundle),
                         classifierModelURL: classifier,
                         orientationModelURL: GarmentOrientationModelProvider.resourceURL(in: bundle))
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
        _ = try orientationProvider.classify(image, deviceOrientation: .up)
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
        let calculationIDs = kind == .top ? ["top_length_start"] : ["thigh_right"]
        let known = Set(provider.schema.keypoints + provider.schema.derivedOrder + calculationIDs)
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
            mask: result.selection.mask, garmentKind: result.recognition.garmentKind,
            recognitionDiagnostics: result.recognition.diagnostics)
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
        case .ambiguous, .noDetection: throw Self.recognitionFailure(in: evaluation)
        }
    }

    /// Report the deepest stage that actually ran rather than labelling every
    /// pose or silhouette rejection as a failure to classify clothing.
    nonisolated static func recognitionFailure(in evaluation: AutoGarmentRecognitionEvaluation) -> AutoGarmentRecognitionError {
        if evaluation.isUnsupported { return .unsupported }
        for attempt in evaluation.classificationAttempts {
            if let evidence = attempt.evidence, evidence.status != .supported,
               !evidence.reasons.contains(.unmatchedForeground) {
                if evidence.reasons.contains(.invalidInput) { return .invalidProvenance }
                return .shapeUnverified(evidence.kind)
            }
        }
        for attempt in evaluation.classificationAttempts where attempt.poseError == "unmatchedForeground" {
            if let kind = attempt.route.garmentKind { return .foregroundMismatch(kind) }
        }
        if evaluation.classificationAttempts.contains(where: { $0.poseError == "noForeground" }) {
            return .foregroundNotFound
        }
        for attempt in evaluation.classificationAttempts where attempt.poseError == "noDetection" {
            if let kind = attempt.route.garmentKind { return .poseNotFound(kind) }
        }
        return evaluation.decision == .ambiguous ? .ambiguous : .noDetection
    }

    /// Four-way correction is chosen once from this frozen RGB. Category, pose
    /// and mask observe the same composed orientation, with no second half-turn
    /// retry and no comparison of category scores across rotations.
    func evaluateImage(_ source: CGImage, orientation: ImageOrientation) async throws -> AutoGarmentRecognitionEvaluation {
        try Task.checkCancellation()
        let image = try analysisImage(source)
        let size = PixelSize(width: image.width, height: image.height)
        guard size.isValid else { throw BottomModelError.invalidImage }
        let orientationPrediction = try orientationProvider.classify(image, deviceOrientation: orientation)
        let composedOrientation = GarmentOrientationTransform.composed(device: orientation,
            correction: orientationPrediction.correction)
        var attempts: [AutoGarmentClassificationAttempt] = []
        var topEvidence: GarmentKindEvidence?, bottomEvidence: GarmentKindEvidence?
        var hadUncertainty = false
        var poseRequests: Int? = 0, foregroundRequests: Int? = 0
        var poseAttempts: [GarmentPoseValidationAttempt] = []
        for direction in [composedOrientation] {
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
                var result: GarmentForegroundRecognition
                do {
                    // The direction classifier already owns rotation selection.
                    // Exact pose and masks each invert the composed transform once.
                    result = try await provider.recognizeForegroundExactly(image, orientation: direction)
                    try Task.checkCancellation()
                    if let count = poseRequests { poseRequests = count + result.poseRequests }
                    if let count = foregroundRequests { foregroundRequests = count + result.foregroundRequests }
                    attempt.poseAttempts = result.recognition.diagnostics?.poseAttempts
                    poseAttempts.append(contentsOf: attempt.poseAttempts ?? [])
                } catch let error as GarmentForegroundValidationFailure {
                    attempt.evidence = .unmatched(kind: kind)
                    attempt.poseError = error.diagnosisCode
                    attempt.poseAttempts = error.attempts
                    poseAttempts.append(contentsOf: error.attempts)
                    if kind == .top { topEvidence = attempt.evidence } else { bottomEvidence = attempt.evidence }
                    if let count = poseRequests { poseRequests = count + error.attempts.count }
                    if let count = foregroundRequests {
                        foregroundRequests = count + error.attempts.filter { $0.rawPoints != nil }.count
                    }
                    attempts.append(attempt)
                    continue
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
                let rawPoints = result.recognition.diagnostics?.rawPoints ?? result.recognition.points
                let evidence = GarmentKindSelectionPolicy.evaluate(kind: kind, points: rawPoints,
                    selection: result.selection, imageSize: size)
                attempt.evidence = evidence
                attempts.append(attempt)
                if kind == .top { topEvidence = evidence } else { bottomEvidence = evidence }
                switch evidence.status {
                case .supported:
                    result.recognition.diagnostics?.requestedOrientation = orientation
                    result.recognition.diagnostics?.orientationPrediction = orientationPrediction
                    result.recognition.diagnostics?.orientationModelVersion = GarmentOrientationModelProvider.modelVersion
                    result.recognition.diagnostics?.poseAttempts = poseAttempts
                    result.recognition.diagnostics?.kindEvidence = evidence
                    result.recognition.diagnostics?.classifiedCategory = route.category
                    result.recognition.diagnostics?.classifierConfidence = route.confidence
                    result.recognition.diagnostics?.classifierScores = scores
                    return .init(decision: .selected(kind), top: topEvidence, bottoms: bottomEvidence,
                                 recognition: result, classificationAttempts: attempts, isUnsupported: false,
                                 poseRequests: poseRequests, foregroundRequests: foregroundRequests,
                                 orientationPrediction: orientationPrediction)
                case .uncertain: hadUncertainty = true
                case .rejected: break
                }
            }
        }
        let unsupported = attempts.allSatisfy { if case .unsupported = $0.route { return true }; return false }
        return .init(decision: hadUncertainty ? .ambiguous : .noDetection,
                     top: topEvidence, bottoms: bottomEvidence, recognition: nil,
                     classificationAttempts: attempts, isUnsupported: unsupported,
                     poseRequests: poseRequests, foregroundRequests: foregroundRequests,
                     orientationPrediction: orientationPrediction)
    }

    /// The fresh-photo fallback uses the same bounded, complete-field sRGB
    /// raster as the preview. Resize without rotating, cropping or stretching;
    /// normalized points and masks still refer to the original sensor image.
    private func analysisImage(_ source: CGImage) throws -> CGImage {
        let original = PixelSize(width: source.width, height: source.height)
        guard original.isValid else { throw BottomModelError.invalidImage }
        let size = LivePreviewRasterGeometry.analysisSize(for: original) ?? original
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        if size == original, source.colorSpace?.name == sRGB.name, source.bitsPerPixel == 32 { return source }
        let scale = Double(size.width) / Double(original.width)
        let resized = CIImage(cgImage: source).transformed(by: .init(scaleX: scale, y: scale))
        guard let image = context.createCGImage(resized,
            from: CGRect(x: 0, y: 0, width: size.width, height: size.height),
            format: .RGBA8, colorSpace: sRGB, deferred: false) else { throw BottomModelError.bufferCreation }
        return image
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
