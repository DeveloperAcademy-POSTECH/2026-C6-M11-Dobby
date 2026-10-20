import Foundation
import CoreML
import CoreImage
import CoreVideo
import ImageIO

nonisolated struct BottomPhotoRecognition: Sendable {
    var imageJPEG: Data
    var imageSize: PixelSize
    var points: [GarmentLandmark]
    var detectionConfidence: Double
    var modelVersion: String
    var durationSeconds: Double
}

/// Exact-orientation automatic recognition retains failed candidates for a
/// later successful half-turn's diagnostic record. Only existing recoverable
/// pose/foreground errors are wrapped; clutter, configuration and cancellation
/// keep their original error identity and cannot be retried through this type.
nonisolated struct GarmentForegroundValidationFailure: Error, LocalizedError, Sendable,
    AutomaticMeasurementFailureClassifying {
    let originalError: any Error
    let diagnosisCode: String
    let attempts: [GarmentPoseValidationAttempt]

    init?(_ error: any Error, attempts: [GarmentPoseValidationAttempt]) {
        let code: String
        switch error {
        case BottomLandmarkError.noDetection: code = "noDetection"
        case GarmentMaskAssociationError.unmatchedGarment: code = "unmatchedForeground"
        case GarmentMaskAssociationError.noForeground: code = "noForeground"
        default: return nil
        }
        originalError = error
        diagnosisCode = code
        self.attempts = attempts
    }

    var errorDescription: String? { originalError.localizedDescription }
    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode { .providerFailure }
}

nonisolated enum BottomModelError: Error, LocalizedError, AutomaticMeasurementFailureClassifying {
    case missingResources, invalidImage, imageSizeMismatch, incompatibleModel, bufferCreation

    var errorDescription: String? {
        switch self {
        case .missingResources: "하의 모델 파일을 찾지 못했습니다. 앱에 모델과 스키마가 포함되어 있는지 확인해 주세요."
        case .invalidImage: "사진을 읽을 수 없습니다. 다른 사진을 선택해 주세요."
        case .imageSizeMismatch: "사진 크기가 촬영 프레임 정보와 다릅니다. 같은 프레임의 사진과 깊이가 필요합니다."
        case .incompatibleModel: "하의 모델의 입력 또는 출력 형식이 스키마와 맞지 않습니다."
        case .bufferCreation: "모델 입력 이미지를 만들지 못했습니다."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .missingResources, .incompatibleModel: .invalidConfiguration
        case .imageSizeMismatch: .frameMismatch
        default: .providerFailure
        }
    }
}

/// One synchronous selection pipeline, shared by the real adapter and injected
/// fixture tests. Both closures observe the same frozen RGB image; each direction
/// runs inference/segmentation at most once. Subject retry reuses those masks.
nonisolated enum GarmentForegroundPoseSelection {
    static func recognize(
        orientation: ImageOrientation, allowsHalfTurn: Bool, recordsRecoverableFailures: Bool,
        imageSize size: PixelSize, schemaKind: AutomaticGarmentKind?, modelVersion: String,
        infer: (ImageOrientation) throws -> BottomLandmarkPrediction,
        masks: (ImageOrientation) throws -> [GarmentMask]
    ) throws -> GarmentForegroundRecognition {
        var attempts: [GarmentPoseValidationAttempt] = []
        var observed: [(orientation: ImageOrientation, prediction: BottomLandmarkPrediction,
                        masks: [GarmentMask], attemptIndex: Int)] = []
        var poseRequests = 0, foregroundRequests = 0
        var result: GarmentForegroundRecognition
        do {
            result = try GarmentPoseOrientationRecovery.perform(orientation: orientation,
                allowsHalfTurn: allowsHalfTurn, strictAttempt: { direction in
                    let index = attempts.count
                    attempts.append(.init(orientation: direction))
                    do {
                        poseRequests += 1
                        let prediction = try infer(direction)
                        attempts[index].rawPoints = prediction.points
                        try Task.checkCancellation()
                        foregroundRequests += 1
                        let masks = try masks(direction)
                        try Task.checkCancellation()
                        observed.append((direction, prediction, masks, index))
                        let selection = try GarmentMaskAssociation.select(masks: masks,
                            points: prediction.points, imageSize: size)
                        attempts[index].associationPolicy = selection.policy
                        attempts[index].pointAssessments = selection.pointAssessments
                        return try foregroundResult(prediction: prediction, selection: selection, modelVersion: modelVersion,
                            requestedOrientation: orientation, selectedOrientation: direction, imageSize: size, schemaKind: schemaKind)
                    } catch {
                        attempts[index].failure = diagnosticFailure(error)
                        throw error
                    }
                }, subjectAttempt: { direction in
                    guard let attempt = observed.last(where: { $0.orientation == direction }),
                          let kind = schemaKind else { return nil }
                    do {
                        // Identify a single subject without letting independent
                        // segmentation erase or replace a viable original pose.
                        // Anatomical support is still mandatory; three arbitrary
                        // foreground points alone cannot identify clothing.
                        let selection = try GarmentMaskAssociation.select(masks: attempt.masks,
                            points: attempt.prediction.points, imageSize: size, policy: .subject)
                        let index = attempt.attemptIndex
                        attempts[index].associationPolicy = selection.policy
                        attempts[index].pointAssessments = selection.pointAssessments
                        let evidence = GarmentKindSelectionPolicy.evaluate(kind: kind,
                            points: attempt.prediction.points, selection: selection, imageSize: size)
                        guard evidence.status == .supported else {
                            attempts[index].failure = "unsupportedPoseStructure"
                            return nil
                        }
                        attempts[index].failure = nil
                        return try foregroundResult(prediction: attempt.prediction, selection: selection, modelVersion: modelVersion,
                            requestedOrientation: orientation, selectedOrientation: direction, imageSize: size, schemaKind: schemaKind,
                            kindEvidence: evidence)
                    } catch GarmentMaskAssociationError.unmatchedGarment {
                        return nil
                    }
                })
        } catch {
            if recordsRecoverableFailures,
               let diagnosed = GarmentForegroundValidationFailure(error, attempts: attempts) {
                throw diagnosed
            }
            throw error
        }
        result.recognition.diagnostics?.poseAttempts = attempts
        result.poseRequests = poseRequests
        result.foregroundRequests = foregroundRequests
        return result
    }

    private static func foregroundResult(
        prediction: BottomLandmarkPrediction, selection: GarmentMaskSelection, modelVersion: String,
        requestedOrientation: ImageOrientation, selectedOrientation: ImageOrientation, imageSize: PixelSize,
        schemaKind: AutomaticGarmentKind?, kindEvidence: GarmentKindEvidence? = nil
    ) throws -> GarmentForegroundRecognition {
        let snapped = try GarmentOutlineSnap.apply(points: prediction.points, mask: selection.mask,
            imageSize: imageSize)
        // A contour request is calculation metadata, not a twelfth prediction.
        // Add it only after the original model candidate has passed association;
        // diagnostics and anatomical validation keep the untouched raw outputs.
        let calculationPoints = schemaKind == .top && modelVersion == AutomaticGarmentKind.top.modelVersion
            ? TopLandmarkSchema.calculationPoints(snapped.points) : snapped.points
        let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: requestedOrientation,
            selectedPoseOrientation: selectedOrientation, associationPolicy: selection.policy,
            rawPoints: prediction.points, pointAssessments: selection.pointAssessments,
            poseAttempts: [], kindEvidence: kindEvidence, automaticAdjustments: snapped.adjustments)
        return .init(recognition: .init(points: calculationPoints, detectionConfidence: prediction.detectionConfidence,
                                       modelVersion: modelVersion, diagnostics: diagnostics), selection: selection)
    }

    private static func diagnosticFailure(_ error: Error) -> String {
        switch error {
        case BottomLandmarkError.noDetection: "noDetection"
        case GarmentMaskAssociationError.unmatchedGarment: "unmatchedForeground"
        case GarmentMaskAssociationError.noForeground: "noForeground"
        default: String(reflecting: error)
        }
    }
}

/// A cached, serial inference service. Image processing and Core ML never run on
/// the main actor. This adapter does not own a camera or invent depth for photos.
actor CoreMLBottomLandmarkProvider: GarmentLandmarkProviding, GarmentImageRecognizing {
    nonisolated let schema: BottomLandmarkSchema
    nonisolated let modelVersion: String
    private let modelURL: URL
    private let allowsHalfTurnRecovery: Bool
    private let orientationProvider: GarmentOrientationModelProvider?
    private var model: MLModel?
    private var hasPrepared = false
    private var hasPreparedForeground = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let foreground = GarmentForegroundMaskAnalyzer()

    init(modelURL: URL, schema: BottomLandmarkSchema, modelVersion: String = "bottom7-976144d4d652",
         allowsHalfTurnRecovery: Bool = false, orientationModelURL: URL? = nil) {
        self.modelURL = modelURL
        self.schema = schema
        self.modelVersion = modelVersion
        self.allowsHalfTurnRecovery = allowsHalfTurnRecovery
        self.orientationProvider = orientationModelURL.map { .init(modelURL: $0) }
    }

    /// Load and exercise the model before live recognition starts. The actor
    /// serializes warm-up with inference and retains only one prepared model.
    func prepare() async throws {
        try preparePoseModel()
        guard !hasPreparedForeground else { return }
        let image = try neutralImage()
        _ = try orientationProvider?.classify(image, deviceOrientation: .up)
        do { _ = try foreground.masks(for: image) }
        catch GarmentMaskAssociationError.noForeground {}
        try Task.checkCancellation()
        hasPreparedForeground = true
    }

    /// The automatic adapter prepares Vision separately. Warm only the pose
    /// here so foreground preparation is not repeated for both cached models.
    func preparePoseModel() throws {
        guard !hasPrepared else { return }
        try Task.checkCancellation()
        _ = try loadedModel()
        let image = try neutralImage()
        let geometry = try BottomLetterboxGeometry(originalSize: .init(width: 640, height: 640), orientation: .up)
        let tensor = try predictionTensor(for: letterboxedBuffer(image, geometry: geometry))
        let shape = tensor.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[1] == 5 + 3 * schema.keypoints.count,
              shape[2] > 0, shape[2] <= 100_000 else { throw BottomModelError.incompatibleModel }
        try Task.checkCancellation()
        hasPrepared = true
    }

    private func neutralImage() throws -> CGImage {
        let neutral = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 640))
        guard let image = context.createCGImage(neutral, from: neutral.extent) else {
            throw BottomModelError.bufferCreation
        }
        return image
    }

    /// One exact orientation for model diagnostics, without Vision or recovery.
    func posePrediction(_ image: CGImage, orientation: ImageOrientation) throws -> BottomLandmarkPrediction {
        try infer(image, orientation: orientation)
    }

    nonisolated static func bundled(in bundle: Bundle = .main) throws -> CoreMLBottomLandmarkProvider {
        guard let modelURL = bundle.url(forResource: "BottomLandmarks", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "BottomLandmarks", withExtension: "mlpackage"),
              let schemaURL = bundle.url(forResource: "schema_bottom8", withExtension: "json") else {
            throw BottomModelError.missingResources
        }
        return try CoreMLBottomLandmarkProvider(modelURL: modelURL,
            schema: BottomLandmarkSchema(jsonData: Data(contentsOf: schemaURL)),
            modelVersion: AutomaticGarmentKind.bottoms.modelVersion,
            orientationModelURL: GarmentOrientationModelProvider.resourceURL(in: bundle))
    }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        let cg = try rawImage(snapshot.imageJPEG)
        guard cg.width == snapshot.frame.imageSize.width, cg.height == snapshot.frame.imageSize.height else {
            throw BottomModelError.imageSizeMismatch
        }
        // Recompute from this frozen RGB. A live preview mask belongs to an
        // earlier frame and must never be attached to these measured points.
        let result = try recognizedForeground(cg, orientation: snapshot.frame.orientation)
        try Task.checkCancellation()
        return GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .model, modelVersion: modelVersion, points: result.recognition.points, mask: result.selection.mask,
            recognitionDiagnostics: result.recognition.diagnostics)
    }

    func recognizeImage(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentImageRecognition {
        try Task.checkCancellation()
        let prediction = try recognizedPoints(image, orientation: orientation)
        try Task.checkCancellation()
        return .init(points: calculationPoints(prediction.points), detectionConfidence: prediction.detectionConfidence,
                     modelVersion: modelVersion)
    }

    func recognizeForeground(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        try Task.checkCancellation()
        return try recognizedForeground(image, orientation: orientation)
    }

    func recognizeForegroundExactly(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        try Task.checkCancellation()
        return try recognizedForeground(image, orientation: orientation, allowsOrientationRecovery: false)
    }

    /// EXIF orientation (including mirrored photos) is baked in exactly once.
    /// This photo-only path returns points, never a centimetre estimate.
    func recognizePhoto(_ data: Data) async throws -> BottomPhotoRecognition {
        let start = ContinuousClock.now
        try Task.checkCancellation()
        guard let photo = CIImage(data: data, options: [.applyOrientationProperty: true]),
              photo.extent.width > 0, photo.extent.height > 0,
              photo.extent.width <= 16_384, photo.extent.height <= 16_384,
              let upright = context.createCGImage(photo, from: photo.extent) else {
            throw BottomModelError.invalidImage
        }
        let prediction = try recognizedPoints(upright, orientation: .up)
        try Task.checkCancellation()
        guard let jpeg = context.jpegRepresentation(of: CIImage(cgImage: upright),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]) else {
            throw BottomModelError.invalidImage
        }
        let elapsed = start.duration(to: .now).components
        return .init(imageJPEG: jpeg, imageSize: .init(width: upright.width, height: upright.height),
            points: calculationPoints(prediction.points), detectionConfidence: prediction.detectionConfidence,
            modelVersion: modelVersion,
            durationSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    private func recognizedPoints(_ image: CGImage, orientation: ImageOrientation) throws -> BottomLandmarkPrediction {
        if let orientationProvider {
            let prediction = try orientationProvider.classify(image, deviceOrientation: orientation)
            let composed = GarmentOrientationTransform.composed(device: orientation, correction: prediction.correction)
            return try infer(image, orientation: composed)
        }
        return try GarmentPoseOrientationRecovery.perform(orientation: orientation,
            allowsHalfTurn: allowsHalfTurnRecovery,
            strictAttempt: { try infer(image, orientation: $0) })
    }

    private func recognizedForeground(_ image: CGImage, orientation: ImageOrientation,
                                     allowsOrientationRecovery: Bool? = nil) throws -> GarmentForegroundRecognition {
        let prediction = allowsOrientationRecovery == false ? nil
            : try orientationProvider?.classify(image, deviceOrientation: orientation)
        let composed = prediction.map { GarmentOrientationTransform.composed(device: orientation, correction: $0.correction) }
            ?? orientation
        var result = try GarmentForegroundPoseSelection.recognize(orientation: composed,
            allowsHalfTurn: prediction == nil && (allowsOrientationRecovery ?? allowsHalfTurnRecovery),
            recordsRecoverableFailures: allowsOrientationRecovery == false,
            imageSize: .init(width: image.width, height: image.height),
            schemaKind: canonicalSchemaKind, modelVersion: modelVersion,
            infer: { try infer(image, orientation: $0) },
            masks: { try foreground.masks(for: image, orientation: $0) })
        result.recognition.diagnostics?.requestedOrientation = orientation
        result.recognition.diagnostics?.orientationPrediction = prediction
        if prediction != nil { result.recognition.diagnostics?.orientationModelVersion = GarmentOrientationModelProvider.modelVersion }
        return result
    }

    /// Photo-only previews have no depth, so keep this request invisible until
    /// a frozen-frame measurement engine can resolve the actual intersection.
    private func calculationPoints(_ points: [GarmentLandmark]) -> [GarmentLandmark] {
        canonicalSchemaKind == .top && modelVersion == AutomaticGarmentKind.top.modelVersion
            ? TopLandmarkSchema.calculationPoints(points) : points
    }

    private var canonicalSchemaKind: AutomaticGarmentKind? {
        if schema.name == "top", schema.keypoints == TopLandmarkSchema.expectedKeypoints { return .top }
        if schema.name == "bottom8", schema.keypoints == BottomLandmarkSchema.expectedBottom8Keypoints { return .bottoms }
        // Explicit legacy adapters remain valid for recorded test fixtures; a
        // newly bundled model always uses the strict bottom8 resource contract.
        if schema.name == "bottom7", schema.keypoints == BottomLandmarkSchema.expectedBottom7Keypoints { return .bottoms }
        return nil
    }

    private func rawImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384 else {
            throw BottomModelError.invalidImage
        }
        return image
    }

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        try Task.checkCancellation()
        let compiledURL = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let inputs = loaded.modelDescription.inputDescriptionsByName
        guard inputs.count == 1, let image = inputs["image"]?.imageConstraint,
              image.pixelsWide == 640, image.pixelsHigh == 640 else {
            throw BottomModelError.incompatibleModel
        }
        self.model = loaded
        return loaded
    }

    private func infer(_ image: CGImage, orientation: ImageOrientation) throws -> BottomLandmarkPrediction {
        try Task.checkCancellation()
        let geometry = try BottomLetterboxGeometry(originalSize: .init(width: image.width, height: image.height),
            orientation: orientation)
        let input = try letterboxedBuffer(image, geometry: geometry)
        let tensor = try predictionTensor(for: input)
        return try CoreMLTensorReader.decode(tensor: tensor, schema: schema, geometry: geometry)
    }

    private func predictionTensor(for input: CVPixelBuffer) throws -> MLMultiArray {
        let model = try loadedModel()
        try Task.checkCancellation()
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let result = try model.prediction(from: features)
        try Task.checkCancellation()
        let arrays = result.featureNames.compactMap { result.featureValue(for: $0)?.multiArrayValue }
        guard arrays.count == 1, let tensor = arrays.first else { throw BottomModelError.incompatibleModel }
        return tensor
    }

    private func letterboxedBuffer(_ image: CGImage, geometry: BottomLetterboxGeometry) throws -> CVPixelBuffer {
        let exif: Int32
        switch geometry.orientation {
        case .up: exif = 1
        case .right: exif = 6
        case .down: exif = 3
        case .left: exif = 8
        }
        let rotated = CIImage(cgImage: image).oriented(forExifOrientation: exif)
        let upright = rotated.transformed(by: .init(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        let resized = upright.transformed(by: .init(
            scaleX: Double(geometry.resizedSize.width) / upright.extent.width,
            y: Double(geometry.resizedSize.height) / upright.extent.height))
            .transformed(by: .init(translationX: Double(geometry.padLeft), y: Double(geometry.padBottom)))
        let extent = CGRect(x: 0, y: 0, width: geometry.inputSize, height: geometry.inputSize)
        let background = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255))
            .cropped(to: extent)
        let canvas = resized.composited(over: background).cropped(to: extent)
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, geometry.inputSize, geometry.inputSize,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw BottomModelError.bufferCreation }
        context.render(canvas, to: buffer, bounds: extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
