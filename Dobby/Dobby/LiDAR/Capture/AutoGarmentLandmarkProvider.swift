import CoreImage
import CoreML
import Foundation
import ImageIO
import os
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
        case .poseNotFound(let kind): "분류기는 \(kind.title)로 판단했지만 해당 측정점을 찾지 못했어요. 이 사진에서 점을 직접 지정할 수 있어요."
        case .foregroundNotFound: "사진에서 옷의 윤곽을 분리하지 못했어요. 옷과 구분되는 배경에서 촬영하거나, 이 사진에서 점을 확인해 주세요."
        case .foregroundMismatch(let kind): "\(kind.title)의 측정점과 사진 속 옷 윤곽이 충분히 일치하지 않아요. 옷과 구분되는 배경에서 촬영하거나, 이 사진에서 점을 확인해 주세요."
        case .shapeUnverified(let kind):
            kind == .top
                ? "분류기는 상의로 판단했지만 몸통과 소매 구조를 확인하지 못했어요. 옷 종류가 잘못 분류됐을 수 있어요."
                : "분류기는 하의로 판단했지만 허리와 양쪽 다리 구조를 확인하지 못했어요. 옷 종류가 잘못 분류됐을 수 있어요."
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
    var orientationResolution: GarmentOrientationResolution? = nil
}

nonisolated struct AutoGarmentImageClassification: Sendable {
    var orientationResolution: GarmentOrientationResolution
    var scores: [GarmentClassificationScore]
    var route: GarmentClassifierRoute
}

nonisolated struct OuterwearComparisonClassification: Sendable {
    var category: String
    var orientation: ImageOrientation
    var prediction: GarmentOrientationPrediction
    var orientationResolution: GarmentOrientationResolution
    var scores: [GarmentClassificationScore]
    var route: GarmentClassifierRoute
}

/// The supplied fifteen-category classifier routes this exact RGB frame to one
/// cached pose model. That model independently associates its points with a
/// foreground mask. A fresh-photo fallback never borrows another frame's points.
actor AutoGarmentLandmarkProvider: GarmentMeasurementDefinitionProviding, GarmentImageRecognizing {
    private static let modelLoadSignposter = OSSignposter(subsystem: "com.dobby.lidar", category: .pointsOfInterest)
    private nonisolated let top: CoreMLGarmentLandmarkProvider
    private nonisolated let bottoms: CoreMLGarmentLandmarkProvider
    private let orientationProvider: GarmentOrientationModelProvider
    private let classifierURL: URL
    private nonisolated let outerwear: (any OuterwearLandmarkProviding)?
    private var classifier: VNCoreMLModel?
    private let foreground = GarmentForegroundMaskAnalyzer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var hasPrepared = false

    // Rejection heuristics for this uncalibrated classifier. A passing category
    // must still have independent pose and silhouette evidence on the same RGB.
    private static let minimumClassScore = 0.10
    private static let minimumCrossKindMargin = 0.01

    init(top: CoreMLGarmentLandmarkProvider, bottoms: CoreMLGarmentLandmarkProvider,
         classifierModelURL: URL, orientationModelURL: URL? = nil,
         outerwear: (any OuterwearLandmarkProviding)? = nil) throws {
        guard top.kind == .top, bottoms.kind == .bottoms else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        self.top = top
        self.bottoms = bottoms
        self.classifierURL = classifierModelURL
        self.outerwear = outerwear
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
                         orientationModelURL: GarmentOrientationModelProvider.resourceURL(in: bundle),
                         outerwear: OuterwearLandmarkClient.makeDefault())
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
        let calculationIDs = kind == .top
            ? (["top_length_start"] + (GarmentLandmarkModelContract.isViewLengthOuterwear(version: landmarks.modelVersion, kind: kind)
                ? ["front_length_start"] : [])) : ["thigh_right"]
        let known = Set(provider.schema.keypoints + provider.schema.derivedOrder + calculationIDs)
        guard GarmentLandmarkModelContract.isCurrent(version: landmarks.modelVersion, kind: kind),
              !identifiers.isEmpty,
              identifiers.count == landmarks.points.count,
              identifiers.isSubset(of: known) else {
            throw AutoGarmentRecognitionError.invalidProvenance
        }
        if GarmentLandmarkModelContract.isViewLengthOuterwear(version: landmarks.modelVersion, kind: kind) {
            return TopLandmarkSchema.viewLengthMeasurementDefinitions(for: landmarks.recognitionDiagnostics?.remoteView)
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

    /// Verify the photo's upright correction before applying the existing
    /// category gate once for all three arms. Preparation is entirely local.
    func classifyOuterwearComparison(_ source: CGImage) throws -> OuterwearComparisonClassification {
        let classification = try classifyCapturedImage(source, orientation: .up)
        let resolution = classification.orientationResolution
        let category = try OuterwearComparisonClassificationPolicy.category(route: classification.route, scores: classification.scores)
        return .init(category: category, orientation: resolution.orientation,
            prediction: resolution.attempts[0].prediction, orientationResolution: resolution,
            scores: classification.scores, route: classification.route)
    }

    /// Shared local preparation, also callable without pose/segmentation/network
    /// for diagnosis. The device orientation is the initial transform, not a
    /// second rotation applied after the final garment correction.
    func classifyCapturedImage(_ source: CGImage, orientation: ImageOrientation) throws -> AutoGarmentImageClassification {
        try Task.checkCancellation()
        return try classification(analysisImage(source), startingAt: orientation)
    }

    private func classification(_ image: CGImage, startingAt orientation: ImageOrientation) throws -> AutoGarmentImageClassification {
        let resolution = try GarmentOrientationResolutionPolicy.resolve(startingAt: orientation) {
            try orientationProvider.classify(image, deviceOrientation: $0)
        }
        let scores = try classify(image, orientation: resolution.orientation)
        let route = GarmentClassifierRoutingPolicy.route(scores: scores,
            minimumConfidence: Self.minimumClassScore, minimumCrossKindMargin: Self.minimumCrossKindMargin)
        return .init(orientationResolution: resolution, scores: scores, route: route)
    }

    func recognizeForeground(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        let evaluation = try await evaluateImage(image, orientation: orientation)
        switch evaluation.decision {
        case .selected(let kind):
            guard let result = evaluation.recognition,
                  result.recognition.garmentKind == kind,
                  GarmentLandmarkModelContract.isCurrent(version: result.recognition.modelVersion, kind: kind) else {
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

    /// Verify upright orientation before classifying the frozen RGB once. Pose,
    /// masks and the AI crop share that final transform; category scores never
    /// choose a rotation or override the existing top/bottom routing gates.
    func evaluateImage(_ source: CGImage, orientation: ImageOrientation) async throws -> AutoGarmentRecognitionEvaluation {
        try Task.checkCancellation()
        let image = try analysisImage(source)
        let size = PixelSize(width: image.width, height: image.height)
        guard size.isValid else { throw BottomModelError.invalidImage }
        let classification = try classification(image, startingAt: orientation)
        let orientationResolution = classification.orientationResolution
        let orientationPrediction = orientationResolution.attempts[0].prediction
        let composedOrientation = orientationResolution.orientation
        var attempts: [AutoGarmentClassificationAttempt] = []
        var topEvidence: GarmentKindEvidence?, bottomEvidence: GarmentKindEvidence?
        var hadUncertainty = false
        var poseRequests: Int? = 0, foregroundRequests: Int? = 0
        var poseAttempts: [GarmentPoseValidationAttempt] = []
        for direction in [composedOrientation] {
            try Task.checkCancellation()
            let scores = classification.scores
            let route = classification.route
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
            case .selected(let kind, let category, _):
                let sourceRoute = GarmentLandmarkSourceRoutingPolicy.route(classification: route, scores: scores)
                if sourceRoute == .uncertainOuterwear {
                    hadUncertainty = true
                    attempt.poseError = "uncertainOuterwear"
                    attempts.append(attempt)
                    continue
                }
                let provider = kind == .top ? top : bottoms
                var result: GarmentForegroundRecognition
                do {
                    // The direction classifier already owns rotation selection.
                    // Exact pose and masks each invert the composed transform once.
                    if sourceRoute == .lunaOuterwear {
                        // Preserve seam detail for the remote encoder's 2048 px
                        // garment crop. Returned coordinates are restored to
                        // this complete frozen frame before depth sampling.
                        result = try await recognizeOuterwear(source, orientation: direction, category: category)
                    } else {
                        result = try await provider.recognizeForegroundExactly(image, orientation: direction)
                    }
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
                let evidence: GarmentKindEvidence
                if sourceRoute == .lunaOuterwear {
                    guard let verified = result.recognition.diagnostics?.kindEvidence,
                          verified.kind == .top else { throw AutoGarmentRecognitionError.invalidProvenance }
                    evidence = verified
                } else {
                    evidence = GarmentKindSelectionPolicy.evaluate(kind: kind, points: rawPoints,
                        selection: result.selection, imageSize: size)
                }
                attempt.evidence = evidence
                attempts.append(attempt)
                if kind == .top { topEvidence = evidence } else { bottomEvidence = evidence }
                switch evidence.status {
                case .supported:
                    result.recognition.diagnostics?.requestedOrientation = orientation
                    result.recognition.diagnostics?.orientationPrediction = orientationPrediction
                    result.recognition.diagnostics?.orientationResolution = orientationResolution
                    result.recognition.diagnostics?.orientationModelVersion = GarmentOrientationModelProvider.modelVersion
                    result.recognition.diagnostics?.poseAttempts = poseAttempts
                    result.recognition.diagnostics?.kindEvidence = evidence
                    result.recognition.diagnostics?.classifiedCategory = route.category
                    result.recognition.diagnostics?.classifierConfidence = route.confidence
                    result.recognition.diagnostics?.classifierScores = scores
                    return .init(decision: .selected(kind), top: topEvidence, bottoms: bottomEvidence,
                                 recognition: result, classificationAttempts: attempts, isUnsupported: false,
                                 poseRequests: poseRequests, foregroundRequests: foregroundRequests,
                                 orientationPrediction: orientationPrediction, orientationResolution: orientationResolution)
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
                     orientationPrediction: orientationPrediction, orientationResolution: orientationResolution)
    }

    /// One request per frozen photo. No pose retries, borrowed live-preview
    /// evidence or CoreML score substitution is used for remote observations.
    private func recognizeOuterwear(_ image: CGImage, orientation: ImageOrientation,
                                    category: String) async throws -> GarmentForegroundRecognition {
        guard let outerwear else { throw OuterwearLandmarkClientError.notConfigured }
        return try await OuterwearGarmentCropPipeline.recognize(image, orientation: orientation,
            category: category, provider: outerwear, masks: { [foreground] upright in
                try foreground.masks(for: upright, orientation: .up)
            })
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
        let interval = Self.modelLoadSignposter.beginInterval("GarmentClassifierModelLoad",
            id: Self.modelLoadSignposter.makeSignpostID())
        defer { Self.modelLoadSignposter.endInterval("GarmentClassifierModelLoad", interval) }
        let url = classifierURL.pathExtension == "mlmodelc" ? classifierURL : try MLModel.compileModel(at: classifierURL)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .all
        let model = try MLModel(contentsOf: url, configuration: configuration)
        guard model.modelDescription.inputDescriptionsByName.count == 1,
              model.modelDescription.inputDescriptionsByName.values.first?.imageConstraint != nil else {
            throw AutoGarmentRecognitionError.incompatibleClassifier
        }
        let loaded = try VNCoreMLModel(for: model)
        // Cache only a fully validated model, independently of the requesting
        // photo. A timeout during cold loading must not discard that costly
        // preparation and force the next capture to repeat it. The cancelled
        // caller still throws before it can infer or publish a photo result.
        classifier = loaded
        try Task.checkCancellation()
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
