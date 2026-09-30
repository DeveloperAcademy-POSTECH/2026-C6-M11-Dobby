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

/// A cached, serial inference service. Image processing and Core ML never run on
/// the main actor. This adapter does not own a camera or invent depth for photos.
actor CoreMLBottomLandmarkProvider: GarmentLandmarkProviding, GarmentImageRecognizing {
    nonisolated let schema: BottomLandmarkSchema
    nonisolated let modelVersion = "bottom7-976144d4d652"
    private let modelURL: URL
    private var model: MLModel?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let foreground = GarmentForegroundMaskAnalyzer()

    init(modelURL: URL, schema: BottomLandmarkSchema) {
        self.modelURL = modelURL
        self.schema = schema
    }

    nonisolated static func bundled(in bundle: Bundle = .main) throws -> CoreMLBottomLandmarkProvider {
        guard let modelURL = bundle.url(forResource: "BottomLandmarks", withExtension: "mlmodelc")
                ?? bundle.url(forResource: "BottomLandmarks", withExtension: "mlpackage"),
              let schemaURL = bundle.url(forResource: "schema_bottom7", withExtension: "json") else {
            throw BottomModelError.missingResources
        }
        return try CoreMLBottomLandmarkProvider(modelURL: modelURL,
            schema: BottomLandmarkSchema(jsonData: Data(contentsOf: schemaURL)))
    }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        let cg = try rawImage(snapshot.imageJPEG)
        guard cg.width == snapshot.frame.imageSize.width, cg.height == snapshot.frame.imageSize.height else {
            throw BottomModelError.imageSizeMismatch
        }
        let prediction = try infer(cg, orientation: snapshot.frame.orientation)
        try Task.checkCancellation()
        // Recompute from this frozen RGB. A live preview mask belongs to an
        // earlier frame and must never be attached to these measured points.
        let selection = try foreground.analyze(cg, points: prediction.points)
        try Task.checkCancellation()
        return GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .model, modelVersion: modelVersion, points: prediction.points, mask: selection.mask)
    }

    func recognizeImage(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentImageRecognition {
        try Task.checkCancellation()
        let prediction = try infer(image, orientation: orientation)
        try Task.checkCancellation()
        return .init(points: prediction.points, detectionConfidence: prediction.detectionConfidence,
                     modelVersion: modelVersion)
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
        let prediction = try infer(upright, orientation: .up)
        try Task.checkCancellation()
        guard let jpeg = context.jpegRepresentation(of: CIImage(cgImage: upright),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]) else {
            throw BottomModelError.invalidImage
        }
        let elapsed = start.duration(to: .now).components
        return .init(imageJPEG: jpeg, imageSize: .init(width: upright.width, height: upright.height),
            points: prediction.points, detectionConfidence: prediction.detectionConfidence,
            modelVersion: modelVersion,
            durationSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
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
        let model = try loadedModel()
        try Task.checkCancellation()
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
        let result = try model.prediction(from: features)
        try Task.checkCancellation()
        let arrays = result.featureNames.compactMap { result.featureValue(for: $0)?.multiArrayValue }
        guard arrays.count == 1, let tensor = arrays.first else { throw BottomModelError.incompatibleModel }
        let shape = tensor.shape.map(\.intValue)
        return try BottomLandmarkDecoder(schema: schema).decode(shape: shape, geometry: geometry) { channel, anchor in
            // MLMultiArray indexing respects actual strides and data type.
            tensor[[0, NSNumber(value: channel), NSNumber(value: anchor)]].doubleValue
        }
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
