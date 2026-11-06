import Foundation

/// A garment-outline endpoint, not a rear-neck seam/collar classifier. The neck
/// midpoint selects travel direction only; it never substitutes a failed exit.
nonisolated enum TopContourLength {
    static let algorithmIdentifier = "neck-perpendicular-mask-v1"
    static let sourceLandmarkIDs = ["neck_left", "neck_right", "hem_center"]

    static func start(neckLeft: Point3D, neckRight: Point3D, hem: Point3D,
                      mask: GarmentMask, frame: MeasurementFrame, plane: GarmentPlane) throws -> Point3D {
        do { return try startDetailed(neckLeft: neckLeft, neckRight: neckRight, hem: hem, mask: mask, frame: frame, plane: plane) }
        catch let error as ContextualMeasurementError { throw error.failure }
    }

    static func startDetailed(neckLeft: Point3D, neckRight: Point3D, hem: Point3D,
                              mask: GarmentMask, frame: MeasurementFrame, plane: GarmentPlane) throws -> Point3D {
        let axis = GarmentPlaneGeometry.subtract(neckRight, neckLeft)
        guard GarmentPlaneGeometry.length(axis) >= 0.02 else { throw failure(.contourNeckAxisTooShort) }
        let perpendicular = GarmentPlaneGeometry.cross(plane.normal, axis)
        let magnitude = GarmentPlaneGeometry.length(perpendicular)
        guard magnitude.isFinite, magnitude > 0.000001 else { throw failure(.contourDegenerateDirection) }
        var direction = GarmentPlaneGeometry.scale(perpendicular, 1 / magnitude)
        let towardNeck = GarmentPlaneGeometry.subtract(
            GarmentPlaneGeometry.scale(GarmentPlaneGeometry.add(neckLeft, neckRight), 0.5), hem)
        if GarmentPlaneGeometry.dot(direction, towardNeck) < 0 { direction = GarmentPlaneGeometry.scale(direction, -1) }
        let neckDistance = GarmentPlaneGeometry.dot(direction, towardNeck)
        guard neckDistance.isFinite, neckDistance >= 0.02 else { throw failure(.contourInvalidDirection) }
        guard mask.size.isValid, mask.values.count <= 4_194_304,
              mask.values.count == mask.size.width * mask.size.height,
              mask.values.allSatisfy({ $0 <= 1 }) else { throw ContextualMeasurementError(failure: .invalidMask, context: .init(stage: .input, reason: .malformedMask, scope: .capture)) }
        let exterior = exteriorBackground(mask)
        var entered = false, insideRun = 0, outsideRun = 0
        var lastPixel: Int?
        var boundary: (point: Point3D, distance: Double)?
        for index in 0...2000 {
            let distance = Double(index) * 0.001
            if !entered && distance > 0.03 { throw failure(.contourNoEntry) }
            let position = GarmentPlaneGeometry.add(hem, GarmentPlaneGeometry.scale(direction, distance))
            guard let point = GarmentPlaneGeometry.project(position, frame: frame) else {
                throw failure(.contourLeavesImage)
            }
            let x = Int(floor(point.x * Double(mask.size.width)))
            let y = Int(floor(point.y * Double(mask.size.height)))
            let pixel = y * mask.size.width + x
            if mask.values[pixel] == 1 {
                outsideRun = 0
                if pixel != lastPixel { insideRun += 1 }
                if insideRun >= 3 { entered = true }
                if entered { boundary = (position, distance) }
            } else if entered && exterior[pixel] != 0 {
                if pixel != lastPixel { outsideRun += 1 }
                if outsideRun >= 3, let boundary {
                    guard boundary.distance >= neckDistance * 0.5 else { throw failure(.contourEarlyExit) }
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
            scope: .landmark, affectedLandmarkIDs: ["top_length_start"] + sourceLandmarkIDs,
            recovery: .correctTotalLength))
    }

    /// Original bitmap is immutable. Closed holes are not exterior; a neck
    /// opening connected to the image edge is. Each background pixel is queued once.
    static func exteriorBackground(_ mask: GarmentMask) -> [UInt8] {
        let width = mask.size.width, height = mask.size.height
        var exterior = [UInt8](repeating: 0, count: mask.values.count)
        var queue: [Int32] = []
        queue.reserveCapacity(mask.values.count)
        func enqueue(_ index: Int) {
            guard exterior[index] == 0, mask.values[index] == 0 else { return }
            exterior[index] = 1; queue.append(Int32(index))
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
