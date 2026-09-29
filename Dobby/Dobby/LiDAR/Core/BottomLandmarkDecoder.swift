import Foundation

nonisolated enum BottomLandmarkError: LocalizedError, Equatable, Sendable {
    case invalidSchema(String)
    case invalidGeometry
    case invalidOutputShape
    case invalidCandidate
    case noDetection
    case multipleGarments

    var errorDescription: String? {
        switch self {
        case .invalidSchema(let reason): "하의 측정점 정의를 읽을 수 없습니다. \(reason)"
        case .invalidGeometry: "사진 크기를 처리할 수 없습니다. 다른 원본 사진을 선택해 주세요."
        case .invalidOutputShape: "하의 모델의 출력 형식이 맞지 않습니다. 모델과 측정점 정의의 버전을 확인해 주세요."
        case .invalidCandidate: "하의 인식 결과가 올바르지 않습니다. 옷 전체가 보이도록 다시 촬영해 주세요."
        case .noDetection: "하의를 찾지 못했습니다. 바지 한 벌을 평평하게 펼치고 전체가 보이도록 촬영해 주세요."
        case .multipleGarments: "하의가 여러 벌로 인식되었습니다. 한 벌만 보이도록 촬영해 주세요."
        }
    }
}

/// The model's channel order and measurement graph come from its accompanying schema.
/// The graph can change without making the existing manual pants presets an ML contract.
nonisolated struct BottomLandmarkSchema: Sendable {
    let name: String
    let keypoints: [String]
    let labels: [String: [String]]
    let derived: [String: [String]]
    let skeleton: [[String]]
    let flipPairs: [[String]]
    let derivedOrder: [String]

    private struct Document: Decodable {
        var name: String
        var keypoints: [String]
        var labels: [String: [String]]?
        var derived: [String: [String]]?
        var skeleton: [[String]]
        var flip_pairs: [[String]]?
    }

    init(jsonData: Data) throws {
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: jsonData) }
        catch { throw BottomLandmarkError.invalidSchema("JSON 형식이 올바르지 않습니다.") }
        name = document.name
        keypoints = document.keypoints
        labels = document.labels ?? [:]
        let derivedSources = document.derived ?? [:]
        derived = derivedSources
        skeleton = document.skeleton
        flipPairs = document.flip_pairs ?? []

        let names = keypoints + derived.keys.sorted()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard !name.isEmpty, !keypoints.isEmpty, names.count <= 128,
              names.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }),
              Set(names).count == names.count else {
            throw BottomLandmarkError.invalidSchema("측정점 이름은 중복되지 않아야 합니다.")
        }
        let allNames = Set(names)
        guard labels.keys.allSatisfy(allNames.contains),
              derived.values.allSatisfy({ $0.count >= 2 && Set($0).count == $0.count && $0.allSatisfy(allNames.contains) }) else {
            throw BottomLandmarkError.invalidSchema("파생 측정점의 입력이 올바르지 않습니다.")
        }
        for pairs in [skeleton, flipPairs] {
            var seen = Set<String>()
            for pair in pairs {
                guard pair.count == 2, pair[0] != pair[1], pair.allSatisfy(allNames.contains),
                      seen.insert(pair.sorted().joined(separator: ".")).inserted else {
                    throw BottomLandmarkError.invalidSchema("연결선은 서로 다른 유효한 측정점 두 개가 필요합니다.")
                }
            }
        }
        guard !skeleton.isEmpty else {
            throw BottomLandmarkError.invalidSchema("측정 연결선이 없습니다.")
        }
        var known = Set(keypoints)
        var remaining = Set(derived.keys)
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { derivedSources[$0]!.allSatisfy(known.contains) }.sorted()
            guard !ready.isEmpty else {
                throw BottomLandmarkError.invalidSchema("파생 측정점에 순환 참조가 있습니다.")
            }
            ordered.append(contentsOf: ready)
            known.formUnion(ready)
            remaining.subtract(ready)
        }
        derivedOrder = ordered
    }

    static func decode(_ jsonData: Data) throws -> Self { try .init(jsonData: jsonData) }

    var measurementDefinitions: [MeasurementDefinition] {
        skeleton.map { pair in
            let edge = pair.sorted().joined(separator: ".")
            let title: String
            switch edge {
            case "waist_left.waist_right": title = "허리 단면"
            case "crotch.waist_center": title = "밑위(직선)"
            case "hem_left_outer.waist_left": title = "왼쪽 총장(직선)"
            case "hem_right_outer.waist_right": title = "오른쪽 총장(직선)"
            case "hem_left_inner.hem_left_outer": title = "왼쪽 밑단 단면"
            case "hem_right_inner.hem_right_outer": title = "오른쪽 밑단 단면"
            case "crotch.hem_left_inner": title = "왼쪽 인심(직선)"
            case "crotch.hem_right_inner": title = "오른쪽 인심(직선)"
            default:
                title = pair.map { labels[$0]?.first ?? $0 }.joined(separator: " ↔ ") + "(직선)"
            }
            return .init(id: "bottom.\(edge)", title: title, landmarkIDs: pair)
        }
    }
}

/// Apply orientation first, then render into these exact integer bounds with RGB 114 padding.
/// Integer rounding can give x and y slightly different scales, so inverse mapping uses
/// each actual resized dimension rather than a single idealized floating-point ratio.
nonisolated struct BottomLetterboxGeometry: Sendable, Equatable {
    let originalSize: PixelSize
    let orientation: ImageOrientation
    let inputSize: Int
    let orientedSize: PixelSize
    let resizedSize: PixelSize
    let padLeft: Int
    let padTop: Int
    let padRight: Int
    let padBottom: Int

    init(originalSize: PixelSize, orientation: ImageOrientation, inputSize: Int = 640) throws {
        guard originalSize.isValid, inputSize > 0, inputSize <= 16_384 else {
            throw BottomLandmarkError.invalidGeometry
        }
        self.originalSize = originalSize
        self.orientation = orientation
        self.inputSize = inputSize
        let rotated = orientation == .left || orientation == .right
        orientedSize = rotated ? .init(width: originalSize.height, height: originalSize.width) : originalSize
        let scale = Double(inputSize) / Double(max(orientedSize.width, orientedSize.height))
        let width = Int((Double(orientedSize.width) * scale).rounded(.toNearestOrEven))
        let height = Int((Double(orientedSize.height) * scale).rounded(.toNearestOrEven))
        guard width > 0, height > 0, width <= inputSize, height <= inputSize else {
            throw BottomLandmarkError.invalidGeometry
        }
        resizedSize = .init(width: width, height: height)
        padLeft = (inputSize - width) / 2
        padTop = (inputSize - height) / 2
        padRight = inputSize - width - padLeft
        padBottom = inputSize - height - padTop
    }

    /// Model output is in continuous 640-pixel image coordinates; result is full original RGB.
    /// Do not clamp predictions from padding onto an image edge: that invents a measuring point.
    func originalPoint(modelX: Double, modelY: Double) -> ImagePoint? {
        guard modelX.isFinite, modelY.isFinite else { return nil }
        let displayed = ImagePoint(x: (modelX - Double(padLeft)) / Double(resizedSize.width),
                                   y: (modelY - Double(padTop)) / Double(resizedSize.height))
        // Include the transformed boundary at 1 here: a rotation can map it to original 0.
        guard displayed.x >= 0, displayed.x <= 1, displayed.y >= 0, displayed.y <= 1 else { return nil }
        let original = ImageCoordinateTransform.displayToOriginal(displayed, orientation: orientation)
        return original.isValid ? original : nil
    }
}

nonisolated struct BottomLandmarkPrediction: Sendable {
    let points: [GarmentLandmark]
    let detectionConfidence: Double
}

/// YOLO pose postprocessing, independent of CoreML/MLMultiArray memory layout.
/// `value(channel, anchor)` must honor the source tensor's actual strides.
nonisolated struct BottomLandmarkDecoder: Sendable {
    let schema: BottomLandmarkSchema
    // Detection threshold supplied with the model; NMS is an engineering duplicate filter,
    // not a guarantee that two strongly overlapping garments can be distinguished.
    private let detectionThreshold = 0.25
    private let nmsIntersectionOverUnion = 0.45

    init(schema: BottomLandmarkSchema) { self.schema = schema }

    func decode(shape: [Int], geometry: BottomLetterboxGeometry,
                value: (_ channel: Int, _ anchor: Int) -> Double) throws -> BottomLandmarkPrediction {
        guard shape.count == 3, shape[0] == 1, shape[1] == 5 + 3 * schema.keypoints.count,
              shape[2] > 0, shape[2] <= 100_000 else {
            throw BottomLandmarkError.invalidOutputShape
        }
        var candidates: [Candidate] = []
        for anchor in 0..<shape[2] {
            let score = value(4, anchor)
            guard score.isFinite, score >= detectionThreshold else { continue }
            let x = value(0, anchor), y = value(1, anchor)
            let width = value(2, anchor), height = value(3, anchor)
            guard score <= 1, x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                  width > 0, height > 0, width <= Double(geometry.inputSize) * 2,
                  height <= Double(geometry.inputSize) * 2,
                  x >= 0, y >= 0, x <= Double(geometry.inputSize), y <= Double(geometry.inputSize) else {
                throw BottomLandmarkError.invalidCandidate
            }
            candidates.append(.init(anchor: anchor, score: score, x: x, y: y, width: width, height: height))
        }
        candidates.sort { $0.score == $1.score ? $0.anchor < $1.anchor : $0.score > $1.score }
        guard let best = candidates.first else { throw BottomLandmarkError.noDetection }
        // Greedy NMS only needs to find its second survivor to reject a multi-item frame.
        guard !candidates.dropFirst().contains(where: { best.iou(with: $0) <= nmsIntersectionOverUnion }) else {
            throw BottomLandmarkError.multipleGarments
        }
        var byID: [String: GarmentLandmark] = [:]
        for (index, id) in schema.keypoints.enumerated() {
            let confidence = value(7 + 3 * index, best.anchor)
            guard confidence.isFinite, confidence >= 0, confidence <= 1,
                  let point = geometry.originalPoint(modelX: value(5 + 3 * index, best.anchor),
                                                     modelY: value(6 + 3 * index, best.anchor)) else { continue }
            byID[id] = .init(id: id, point: point, confidence: confidence, isVisible: true)
        }
        for id in schema.derivedOrder {
            let dependencies = schema.derived[id]!
            let inputs = dependencies.compactMap { byID[$0] }
            guard inputs.count == dependencies.count else { continue }
            let count = Double(inputs.count)
            let point = ImagePoint(x: inputs.reduce(0) { $0 + $1.point.x } / count,
                                   y: inputs.reduce(0) { $0 + $1.point.y } / count)
            byID[id] = .init(id: id, point: point, confidence: inputs.compactMap(\.confidence).min(), isVisible: true)
        }
        return .init(points: (schema.keypoints + schema.derivedOrder).compactMap { byID[$0] }, detectionConfidence: best.score)
    }

    private struct Candidate {
        let anchor: Int
        let score: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        func iou(with other: Self) -> Double {
            let intersectionWidth = max(0, min(x + width / 2, other.x + other.width / 2) - max(x - width / 2, other.x - other.width / 2))
            let intersectionHeight = max(0, min(y + height / 2, other.y + other.height / 2) - max(y - height / 2, other.y - other.height / 2))
            let intersection = intersectionWidth * intersectionHeight
            let union = width * height + other.width * other.height - intersection
            return union > 0 ? intersection / union : 0
        }
    }
}
