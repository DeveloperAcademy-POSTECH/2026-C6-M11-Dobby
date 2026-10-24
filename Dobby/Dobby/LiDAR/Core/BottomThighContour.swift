import Foundation

/// Right thigh cross-section through the unchanged crotch, parallel to the
/// waist axis on the accepted garment plane. Inputs are already resolved in
/// native camera coordinates and metres; image-horizontal tracing is not used.
nonisolated enum BottomThighContour {
    static let algorithmIdentifier = "waist-parallel-right-thigh-mask-v1"
    static let sourceLandmarkIDs = ["waist_left", "waist_right", "crotch"]
    static let stepMeters = 0.001
    static let maximumDistanceMeters = 0.60
    static let initialSupportDistanceMeters = 0.03
    static let minimumWidthMeters = 0.02
    static let stablePixelCount = 3
    private static let maximumMaskPixels = 4_194_304

    static func right(waistLeft: Point3D, waistRight: Point3D, crotch: Point3D,
                      mask: GarmentMask, frame: MeasurementFrame) throws -> Point3D {
        let axis = GarmentPlaneGeometry.subtract(waistRight, waistLeft)
        let span = GarmentPlaneGeometry.length(axis)
        guard GarmentPlaneGeometry.finite(waistLeft), GarmentPlaneGeometry.finite(waistRight),
              GarmentPlaneGeometry.finite(crotch), span.isFinite, span > 0.02
        else { throw MeasurementFailure.contourIntersectionUnavailable }
        guard mask.size.isValid, mask.values.count <= maximumMaskPixels,
              mask.values.count == mask.size.width * mask.size.height,
              mask.values.allSatisfy({ $0 <= 1 }) else { throw MeasurementFailure.invalidMask }

        let direction = GarmentPlaneGeometry.scale(axis, 1 / span)
        // Unlike a row's farthest foreground pixel, a stable first exit cannot
        // skip over background to another garment. Closed segmentation holes
        // are not an outer edge; only border-connected background terminates it.
        let exterior = exteriorBackground(mask)
        var entered = false, insideRun = 0, outsideRun = 0
        var lastPixel: Int?
        var boundary: (point: Point3D, distance: Double)?
        let maximumSteps = Int((maximumDistanceMeters / stepMeters).rounded())
        for index in 0...maximumSteps {
            let distance = Double(index) * stepMeters
            guard entered || distance <= initialSupportDistanceMeters else {
                throw MeasurementFailure.contourIntersectionUnavailable
            }
            let position = GarmentPlaneGeometry.add(crotch, GarmentPlaneGeometry.scale(direction, distance))
            guard let point = GarmentPlaneGeometry.project(position, frame: frame) else {
                throw MeasurementFailure.contourIntersectionUnavailable
            }
            let x = Int(floor(point.x * Double(mask.size.width)))
            let y = Int(floor(point.y * Double(mask.size.height)))
            let pixel = y * mask.size.width + x
            if mask.values[pixel] == 1 {
                outsideRun = 0
                if pixel != lastPixel { insideRun += 1 }
                if insideRun >= stablePixelCount { entered = true }
                if entered { boundary = (position, distance) }
            } else if entered && exterior[pixel] != 0 {
                if pixel != lastPixel { outsideRun += 1 }
                if outsideRun >= stablePixelCount, let boundary {
                    guard boundary.distance >= minimumWidthMeters else {
                        throw MeasurementFailure.contourIntersectionUnavailable
                    }
                    return boundary.point
                }
            } else {
                outsideRun = 0
                if !entered { insideRun = 0 }
            }
            lastPixel = pixel
        }
        // A missing or cropped edge must not become an invented 60 cm width.
        throw MeasurementFailure.contourIntersectionUnavailable
    }

    /// Four-connected exterior background. The original mask is never filled or
    /// changed, so plane fitting still sees its actual segmentation holes.
    private static func exteriorBackground(_ mask: GarmentMask) -> [UInt8] {
        let width = mask.size.width, height = mask.size.height
        var exterior = [UInt8](repeating: 0, count: mask.values.count)
        var queue: [Int32] = []
        queue.reserveCapacity(mask.values.count)
        func enqueue(_ index: Int) {
            guard exterior[index] == 0, mask.values[index] == 0 else { return }
            exterior[index] = 1
            queue.append(Int32(index))
        }
        for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
        for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
        var head = 0
        while head < queue.count {
            let index = Int(queue[head]); head += 1
            let x = index % width, y = index / width
            if x > 0 { enqueue(index - 1) }
            if x + 1 < width { enqueue(index + 1) }
            if y > 0 { enqueue(index - width) }
            if y + 1 < height { enqueue(index + width) }
        }
        return exterior
    }
}
