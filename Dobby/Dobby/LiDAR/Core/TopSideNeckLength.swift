import Foundation

/// The image-left side-neck ray follows vertical in the verified upright image.
/// Its hem is a calculated contour endpoint, never an AI hem-center observation.
nonisolated enum TopSideNeckLength {
    static let hemID = "top_length_hem"

    static func applying(to landmarks: GarmentLandmarkSet) -> GarmentLandmarkSet {
        var result = landmarks
        guard result.garmentKind == .top,
              result.modelVersion == GarmentLandmarkModelContract.lunaGapLengthVersion,
              result.recognitionDiagnostics != nil else { return result }
        result.recognitionDiagnostics?.totalLengthConvention = GarmentLandmarkModelContract.sideNeckConvention
        result.points = calculationPoints(result.points)
        return result
    }

    static func calculationPoints(_ points: [GarmentLandmark]) -> [GarmentLandmark] {
        points.filter { $0.id != hemID } + [.init(id: hemID, point: .init(x: 0.5, y: 0.5),
            confidence: nil, isVisible: false, contourRule: .leftNeckVerticalHemMaskV1)]
    }

    static func end(neck: Point3D, mask: GarmentMask, frame: MeasurementFrame,
                    plane: GarmentPlane, orientation: ImageOrientation) throws -> Point3D {
        guard mask.size.isValid, mask.values.count <= 4_194_304,
              mask.values.count == mask.size.width * mask.size.height,
              mask.values.allSatisfy({ $0 <= 1 }) else {
            throw ContextualMeasurementError(failure: .invalidMask,
                context: .init(stage: .input, reason: .malformedMask, scope: .capture))
        }
        guard let rawStart = GarmentPlaneGeometry.project(neck, frame: frame) else {
            throw failure(.contourInvalidDirection)
        }
        let start = ImageCoordinateTransform.originalToDisplay(rawStart, orientation: orientation)
        let step = start.y < 0.98 ? 0.01 : -0.01
        let rawNext = ImageCoordinateTransform.displayToOriginal(
            .init(x: start.x, y: start.y + step), orientation: orientation)
        let next = try GarmentPlaneGeometry.intersectionDetailed(point: rawNext, frame: frame, plane: plane)
        let delta = GarmentPlaneGeometry.scale(GarmentPlaneGeometry.subtract(next, neck), step > 0 ? 1 : -1)
        let magnitude = GarmentPlaneGeometry.length(delta)
        guard magnitude.isFinite, magnitude > 0.000001 else { throw failure(.contourDegenerateDirection) }
        let direction = GarmentPlaneGeometry.scale(delta, 1 / magnitude)
        let bounds = try OuterwearComparisonGeometry.garmentBounds(mask: mask)
        let ys = [(bounds.x, bounds.y), (bounds.x + bounds.width, bounds.y),
                  (bounds.x, bounds.y + bounds.height), (bounds.x + bounds.width, bounds.y + bounds.height)]
            .map { ImageCoordinateTransform.originalToDisplay(.init(x: $0.0, y: $0.1), orientation: orientation).y }
        let top = ys.min()!, bottom = ys.max()!
        let exterior = TopContourLength.exteriorBackground(mask)
        var entered = false, insideRun = 0, outsideRun = 0
        var lastPixel: Int?, boundary: (point: Point3D, distance: Double, y: Double)?
        for index in 0...2000 {
            let distance = Double(index) * 0.001
            if !entered && distance > 0.03 { throw failure(.contourNoEntry) }
            let position = GarmentPlaneGeometry.add(neck, GarmentPlaneGeometry.scale(direction, distance))
            guard let point = GarmentPlaneGeometry.project(position, frame: frame) else {
                throw failure(.contourLeavesImage)
            }
            let pixel = Int(point.y * Double(mask.size.height)) * mask.size.width
                + Int(point.x * Double(mask.size.width))
            if mask.values[pixel] == 1 {
                outsideRun = 0
                if pixel != lastPixel { insideRun += 1 }
                if insideRun >= 3 { entered = true }
                if entered {
                    boundary = (position, distance,
                        ImageCoordinateTransform.originalToDisplay(point, orientation: orientation).y)
                }
            } else if entered && exterior[pixel] != 0 {
                if pixel != lastPixel { outsideRun += 1 }
                if outsideRun >= 3, let boundary {
                    // A neck opening, side slit or early segmentation break is
                    // not a usable lower-body hem. Never jump to another island.
                    guard boundary.distance >= 0.08,
                          boundary.y >= top + (bottom - top) * 0.6 else { throw failure(.contourEarlyExit) }
                    return boundary.point
                }
            } else {
                outsideRun = 0
                if !entered { insideRun = 0 }
            }
            lastPixel = pixel
        }
        throw failure(.contourNoExit)
    }

    private static func failure(_ reason: MeasurementFailureReason) -> ContextualMeasurementError {
        .init(failure: .contourIntersectionUnavailable, context: .init(stage: .contour, reason: reason,
            scope: .landmark, affectedLandmarkIDs: ["neck_left", hemID], recovery: .correctTotalLength))
    }
}
