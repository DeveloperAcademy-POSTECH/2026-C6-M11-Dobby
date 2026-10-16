import Foundation

/// A centered crop of one already registered RGB/depth pair. Both rectangles
/// describe the exact same scene region; depth and confidence pixels are copied
/// without interpolation. This is digital magnification, never a lens switch.
nonisolated struct RegisteredCameraCrop: Codable, Sendable, Equatable {
    let sourceImageSize: PixelSize
    let sourceDepthSize: PixelSize
    let imageOriginX: Int
    let imageOriginY: Int
    let imageSize: PixelSize
    let depthOriginX: Int
    let depthOriginY: Int
    let depthSize: PixelSize
    let requestedZoomFactor: Double
    let effectiveZoomFactor: Double

    /// Accept only an exactly representable requested crop. Rounding either
    /// rectangle independently would shift depth samples relative to RGB.
    static func make(imageSize: PixelSize, depthSize: PixelSize, zoomFactor: Double) -> Self? {
        guard imageSize.isValid, depthSize.isValid, zoomFactor.isFinite, zoomFactor >= 1,
              imageSize.width * depthSize.height == imageSize.height * depthSize.width,
              let imageWidth = exactDimension(imageSize.width, dividedBy: zoomFactor),
              let imageHeight = exactDimension(imageSize.height, dividedBy: zoomFactor),
              let depthWidth = exactDimension(depthSize.width, dividedBy: zoomFactor),
              let depthHeight = exactDimension(depthSize.height, dividedBy: zoomFactor),
              (imageSize.width - imageWidth).isMultiple(of: 2),
              (imageSize.height - imageHeight).isMultiple(of: 2),
              (depthSize.width - depthWidth).isMultiple(of: 2),
              (depthSize.height - depthHeight).isMultiple(of: 2) else { return nil }
        let imageX = (imageSize.width - imageWidth) / 2
        let imageY = (imageSize.height - imageHeight) / 2
        let depthX = (depthSize.width - depthWidth) / 2
        let depthY = (depthSize.height - depthHeight) / 2
        guard imageX * depthSize.width == depthX * imageSize.width,
              imageY * depthSize.height == depthY * imageSize.height,
              imageWidth * depthSize.width == depthWidth * imageSize.width,
              imageHeight * depthSize.height == depthHeight * imageSize.height,
              imageWidth * imageSize.height == imageHeight * imageSize.width,
              depthWidth * depthSize.height == depthHeight * depthSize.width else { return nil }
        let effective = Double(imageSize.width) / Double(imageWidth)
        guard effective == zoomFactor,
              Double(imageSize.height) / Double(imageHeight) == zoomFactor,
              Double(depthSize.width) / Double(depthWidth) == zoomFactor,
              Double(depthSize.height) / Double(depthHeight) == zoomFactor else { return nil }
        return .init(sourceImageSize: imageSize, sourceDepthSize: depthSize,
            imageOriginX: imageX, imageOriginY: imageY,
            imageSize: .init(width: imageWidth, height: imageHeight),
            depthOriginX: depthX, depthOriginY: depthY,
            depthSize: .init(width: depthWidth, height: depthHeight),
            requestedZoomFactor: zoomFactor, effectiveZoomFactor: effective)
    }

    func applying(to depth: DepthMap) -> DepthMap? {
        guard depth.size == sourceDepthSize,
              depth.values.count == sourceDepthSize.width * sourceDepthSize.height else { return nil }
        if let confidence = depth.confidence {
            guard confidence.count == depth.values.count, confidence.allSatisfy({ $0 <= 2 }) else { return nil }
        }
        var values: [Float] = []
        values.reserveCapacity(depthSize.width * depthSize.height)
        var confidence: [UInt8]? = depth.confidence == nil ? nil : []
        confidence?.reserveCapacity(depthSize.width * depthSize.height)
        for row in depthOriginY..<(depthOriginY + depthSize.height) {
            let start = row * sourceDepthSize.width + depthOriginX
            let range = start..<(start + depthSize.width)
            values.append(contentsOf: depth.values[range])
            if let original = depth.confidence { confidence?.append(contentsOf: original[range]) }
        }
        return .init(size: depthSize, values: values, confidence: confidence)
    }

    /// Pixels are cropped without resizing, so focal lengths stay unchanged.
    /// Only the principal point's origin and reference image extent move.
    func applying(to intrinsics: CameraIntrinsics) -> CameraIntrinsics? {
        guard intrinsics.referenceSize == sourceImageSize,
              intrinsics.fx.isFinite, intrinsics.fy.isFinite, intrinsics.fx > 0, intrinsics.fy > 0,
              intrinsics.cx.isFinite, intrinsics.cy.isFinite else { return nil }
        return .init(fx: intrinsics.fx, fy: intrinsics.fy,
            cx: intrinsics.cx - Double(imageOriginX), cy: intrinsics.cy - Double(imageOriginY),
            referenceSize: imageSize)
    }

    func normalizedSourcePoint(fromCropped point: ImagePoint) -> ImagePoint? {
        guard point.isValid else { return nil }
        let source = ImagePoint(
            x: (Double(imageOriginX) + point.x * Double(imageSize.width)) / Double(sourceImageSize.width),
            y: (Double(imageOriginY) + point.y * Double(imageSize.height)) / Double(sourceImageSize.height))
        return source.isValid ? source : nil
    }

    func croppedPoint(fromSource point: ImagePoint) -> ImagePoint? {
        guard point.isValid else { return nil }
        let x = point.x * Double(sourceImageSize.width)
        let y = point.y * Double(sourceImageSize.height)
        guard x >= Double(imageOriginX), x < Double(imageOriginX + imageSize.width),
              y >= Double(imageOriginY), y < Double(imageOriginY + imageSize.height) else { return nil }
        let cropped = ImagePoint(x: (x - Double(imageOriginX)) / Double(imageSize.width),
                                 y: (y - Double(imageOriginY)) / Double(imageSize.height))
        return cropped.isValid ? cropped : nil
    }

    private static func exactDimension(_ dimension: Int, dividedBy factor: Double) -> Int? {
        let divided = Double(dimension) / factor
        guard let value = Int(exactly: divided), value > 0, value <= dimension else { return nil }
        return value
    }

    private init(sourceImageSize: PixelSize, sourceDepthSize: PixelSize,
                 imageOriginX: Int, imageOriginY: Int, imageSize: PixelSize,
                 depthOriginX: Int, depthOriginY: Int, depthSize: PixelSize,
                 requestedZoomFactor: Double, effectiveZoomFactor: Double) {
        self.sourceImageSize = sourceImageSize
        self.sourceDepthSize = sourceDepthSize
        self.imageOriginX = imageOriginX
        self.imageOriginY = imageOriginY
        self.imageSize = imageSize
        self.depthOriginX = depthOriginX
        self.depthOriginY = depthOriginY
        self.depthSize = depthSize
        self.requestedZoomFactor = requestedZoomFactor
        self.effectiveZoomFactor = effectiveZoomFactor
    }

    private enum CodingKeys: String, CodingKey {
        case sourceImageSize, sourceDepthSize, imageOriginX, imageOriginY, imageSize
        case depthOriginX, depthOriginY, depthSize, requestedZoomFactor, effectiveZoomFactor
    }

    /// Imported crop metadata cannot introduce a different ROI or an arbitrary
    /// effective factor. It must reproduce the same validated factory geometry.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceImage = try values.decode(PixelSize.self, forKey: .sourceImageSize)
        let sourceDepth = try values.decode(PixelSize.self, forKey: .sourceDepthSize)
        let requested = try values.decode(Double.self, forKey: .requestedZoomFactor)
        let supplied = try Self(sourceImageSize: sourceImage, sourceDepthSize: sourceDepth,
            imageOriginX: values.decode(Int.self, forKey: .imageOriginX),
            imageOriginY: values.decode(Int.self, forKey: .imageOriginY),
            imageSize: values.decode(PixelSize.self, forKey: .imageSize),
            depthOriginX: values.decode(Int.self, forKey: .depthOriginX),
            depthOriginY: values.decode(Int.self, forKey: .depthOriginY),
            depthSize: values.decode(PixelSize.self, forKey: .depthSize),
            requestedZoomFactor: requested,
            effectiveZoomFactor: values.decode(Double.self, forKey: .effectiveZoomFactor))
        guard let crop = Self.make(imageSize: sourceImage, depthSize: sourceDepth, zoomFactor: requested),
              crop == supplied else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Crop geometry does not preserve registered RGB/depth coordinates."))
        }
        self = crop
    }
}
