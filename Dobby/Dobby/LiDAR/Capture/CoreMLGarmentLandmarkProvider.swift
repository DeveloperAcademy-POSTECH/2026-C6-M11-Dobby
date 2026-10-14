import Foundation
import CoreImage

typealias GarmentPhotoRecognition = BottomPhotoRecognition

nonisolated enum GarmentModelError: Error, LocalizedError, AutomaticMeasurementFailureClassifying {
    case missingResources(AutomaticGarmentKind)
    case incompatibleModel(AutomaticGarmentKind)
    case invalidRecognition(AutomaticGarmentKind)
    case noDetection(AutomaticGarmentKind)
    case multipleGarments(AutomaticGarmentKind)

    var errorDescription: String? {
        switch self {
        case .missingResources(let kind):
            "\(kind.title) 모델 파일을 찾지 못했습니다. 앱에 모델과 측정점 정의가 포함되어 있는지 확인해 주세요."
        case .incompatibleModel(let kind):
            "\(kind.title) 모델과 측정점 정의의 형식이 맞지 않습니다."
        case .invalidRecognition(let kind):
            "\(kind.title) 인식 결과를 사용할 수 없습니다. 옷 전체가 보이도록 다시 촬영해 주세요."
        case .noDetection(let kind):
            "\(kind.title)를 찾지 못했습니다. \(kind.supportDescription) 한 벌을 바닥에 평평하게 펼치고 전체가 보이도록 촬영해 주세요."
        case .multipleGarments(let kind):
            "\(kind.title)가 여러 벌로 인식되었습니다. 한 벌만 보이도록 촬영해 주세요."
        }
    }

    var automaticMeasurementFailureCode: AutomaticMeasurementFailureCode {
        switch self {
        case .missingResources, .incompatibleModel: .invalidConfiguration
        default: .providerFailure
        }
    }
}

/// Both supplied YOLO pose models use the same 640px letterbox contract. Keep
/// preprocessing, raw-frame mapping, cancellation and foreground association in
/// the existing serial adapter rather than introducing a second inference path.
actor CoreMLGarmentLandmarkProvider: GarmentLandmarkProviding, GarmentImageRecognizing {
    nonisolated let kind: AutomaticGarmentKind
    nonisolated let schema: BottomLandmarkSchema
    nonisolated let measurementDefinitions: [MeasurementDefinition]
    nonisolated let modelVersion: String
    nonisolated var keypoints: [String] { schema.keypoints }
    nonisolated var labels: [String: [String]] { schema.labels }
    nonisolated var skeleton: [[String]] { schema.skeleton }
    private let adapter: CoreMLBottomLandmarkProvider

    init(kind: AutomaticGarmentKind, modelURL: URL, schemaData: Data) throws {
        let schema: BottomLandmarkSchema
        let definitions: [MeasurementDefinition]
        do {
            switch kind {
            case .top:
                let top = try TopLandmarkSchema(jsonData: schemaData)
                schema = top.decoderSchema
                definitions = top.measurementDefinitions
            case .bottoms:
                schema = try BottomLandmarkSchema(jsonData: schemaData)
                guard schema.name == "bottom7", schema.keypoints.count == 7 else {
                    throw GarmentModelError.incompatibleModel(kind)
                }
                definitions = schema.measurementDefinitions
            }
        } catch {
            throw GarmentModelError.incompatibleModel(kind)
        }
        self.kind = kind
        self.schema = schema
        self.measurementDefinitions = definitions
        self.modelVersion = kind.modelVersion
        self.adapter = CoreMLBottomLandmarkProvider(modelURL: modelURL, schema: schema,
                                                   modelVersion: kind.modelVersion,
                                                   allowsHalfTurnRecovery: kind == .top)
    }

    func prepare() async throws {
        do { try await adapter.prepare() }
        catch { throw translated(error) }
    }

    func preparePoseModel() async throws {
        do { try await adapter.preparePoseModel() }
        catch { throw translated(error) }
    }

    func posePrediction(_ image: CGImage, orientation: ImageOrientation) async throws -> BottomLandmarkPrediction {
        do { return try await adapter.posePrediction(image, orientation: orientation) }
        catch { throw translated(error) }
    }

    nonisolated static func bundled(kind: AutomaticGarmentKind, in bundle: Bundle = .main) throws -> CoreMLGarmentLandmarkProvider {
        guard let modelURL = bundle.url(forResource: kind.modelResourceName, withExtension: "mlmodelc")
                ?? bundle.url(forResource: kind.modelResourceName, withExtension: "mlpackage"),
              let schemaURL = bundle.url(forResource: kind.schemaResourceName, withExtension: "json") else {
            throw GarmentModelError.missingResources(kind)
        }
        return try .init(kind: kind, modelURL: modelURL, schemaData: Data(contentsOf: schemaURL))
    }

    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        do {
            var result = try await adapter.landmarks(for: snapshot)
            result.garmentKind = kind
            return result
        }
        catch { throw translated(error) }
    }

    func recognizeImage(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentImageRecognition {
        do {
            var result = try await adapter.recognizeImage(image, orientation: orientation)
            result.garmentKind = kind
            return result
        }
        catch { throw translated(error) }
    }

    func recognizeForeground(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        do {
            var result = try await adapter.recognizeForeground(image, orientation: orientation)
            result.recognition.garmentKind = kind
            return result
        }
        catch { throw translated(error) }
    }

    /// Automatic classification owns its bounded orientation retry. Do not run
    /// a second pose direction behind the classifier's chosen direction.
    func recognizeForegroundExactly(_ image: CGImage, orientation: ImageOrientation) async throws -> GarmentForegroundRecognition {
        do {
            var result = try await adapter.recognizeForegroundExactly(image, orientation: orientation)
            result.recognition.garmentKind = kind
            return result
        }
        catch { throw translated(error) }
    }

    func recognizePhoto(_ data: Data) async throws -> GarmentPhotoRecognition {
        do { return try await adapter.recognizePhoto(data) }
        catch { throw translated(error) }
    }

    private func translated(_ error: Error) -> Error {
        if let error = error as? BottomLandmarkError {
            switch error {
            case .noDetection: return GarmentModelError.noDetection(kind)
            case .multipleGarments: return GarmentModelError.multipleGarments(kind)
            case .invalidSchema, .invalidOutputShape: return GarmentModelError.incompatibleModel(kind)
            case .invalidCandidate: return GarmentModelError.invalidRecognition(kind)
            case .invalidGeometry: return error
            }
        }
        if let error = error as? BottomModelError {
            switch error {
            case .missingResources: return GarmentModelError.missingResources(kind)
            case .incompatibleModel: return GarmentModelError.incompatibleModel(kind)
            default: return error
            }
        }
        return error
    }
}
