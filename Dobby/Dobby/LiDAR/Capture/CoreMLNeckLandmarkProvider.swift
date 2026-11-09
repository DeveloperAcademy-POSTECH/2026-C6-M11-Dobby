import CoreGraphics
import CoreML
import Foundation
import Vision

nonisolated protocol LocalNeckLandmarkProviding: Sendable {
    /// Upright garment raster. Results are normalized to this exact raster.
    func neckPoints(in image: CGImage) async throws -> [String: ImagePoint]
}

/// Only requested by the Luna outerwear route, never the ordinary top model.
actor CoreMLNeckLandmarkProvider: LocalNeckLandmarkProviding {
    private let modelURL: URL?
    private var model: VNCoreMLModel?

    init(bundle: Bundle = .main) {
        modelURL = bundle.url(forResource: LocalNeckLandmarks.resourceName, withExtension: "mlmodelc")
            ?? bundle.url(forResource: LocalNeckLandmarks.resourceName, withExtension: "mlpackage")
    }

    init(modelURL: URL) { self.modelURL = modelURL }

    func neckPoints(in image: CGImage) async throws -> [String: ImagePoint] {
        try Task.checkCancellation()
        let request = VNCoreMLRequest(model: try loadedModel())
        // Training resizes the full input directly, without letterboxing or
        // center crop. Per-channel ImageNet normalization lives in the model.
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        try Task.checkCancellation()
        guard let heatmap = (request.results as? [VNCoreMLFeatureValueObservation])?
            .first(where: { $0.featureName == "heatmaps" })?.featureValue.multiArrayValue,
              heatmap.shape.map(\.intValue) == [1, 2, LocalNeckLandmarks.heatmapHeight, LocalNeckLandmarks.heatmapWidth] else {
            throw LocalNeckLandmarkError.invalidOutput
        }
        var values = [Float](); values.reserveCapacity(heatmap.count)
        // Respect Core ML strides instead of assuming contiguous storage.
        for channel in 0..<2 {
            for y in 0..<LocalNeckLandmarks.heatmapHeight {
                for x in 0..<LocalNeckLandmarks.heatmapWidth {
                    values.append(heatmap[[0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]].floatValue)
                }
            }
        }
        return try LocalNeckLandmarks.decode(values)
    }

    private func loadedModel() throws -> VNCoreMLModel {
        if let model { return model }
        guard let modelURL else { throw LocalNeckLandmarkError.missingModel }
        let url = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let config = MLModelConfiguration(); config.computeUnits = .all
        let loaded = try MLModel(contentsOf: url, configuration: config)
        let description = loaded.modelDescription
        guard let input = description.inputDescriptionsByName["image"]?.imageConstraint,
              input.pixelsWide == LocalNeckLandmarks.inputWidth, input.pixelsHigh == LocalNeckLandmarks.inputHeight,
              description.outputDescriptionsByName["heatmaps"]?.multiArrayConstraint?.shape.map(\.intValue)
                == [1, 2, LocalNeckLandmarks.heatmapHeight, LocalNeckLandmarks.heatmapWidth] else {
            throw LocalNeckLandmarkError.incompatibleModel
        }
        let vision = try VNCoreMLModel(for: loaded); model = vision
        return vision
    }
}
