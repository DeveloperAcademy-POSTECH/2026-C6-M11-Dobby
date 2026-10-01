import Foundation

/// Deterministic camera observations of a known plane, independent of the measurement engine.
/// The endpoint vector has length exactly 0.5 metres in both the flat and tilted scenes.
nonisolated enum SyntheticFixtures {
    static func scene(
        tilted: Bool = false,
        noisy: Bool = false,
        missingDepth: Bool = false
    ) -> (frame: MeasurementFrame, landmarks: GarmentLandmarkSet, expectedMeters: Double) {
        let imageSize = PixelSize(width: 800, height: 600)
        let depthSize = PixelSize(width: 160, height: 120)
        let camera = CameraIntrinsics(fx: 600, fy: 600, cx: 400, cy: 300, referenceSize: imageSize)
        let angle = tilted ? 25.0 * Double.pi / 180.0 : 0
        let slope = tan(angle)
        let centreDepth = 1.15
        let halfLength = 0.25
        var depth = [Float]()
        depth.reserveCapacity(depthSize.width * depthSize.height)

        for y in 0..<depthSize.height {
            for x in 0..<depthSize.width {
                // Intersect each pixel ray with z = centreDepth + slope * X.
                let u = (Double(x) + 0.5) * Double(imageSize.width) / Double(depthSize.width)
                let rayX = (u - camera.cx) / camera.fx
                var z = centreDepth / (1 - slope * rayX)
                if noisy {
                    // A fixed spatial hash gives repeatable +/-3 mm noise and rare 20 cm outliers.
                    let hash = (x * 73_856_093) ^ (y * 19_349_663)
                    z += (Double(hash % 601) / 100.0 - 3.0) / 1_000.0
                    if hash % 37 == 0 { z += 0.20 }
                }
                depth.append(missingDepth ? 0 : Float(z))
            }
        }

        func project(_ point: Point3D) -> ImagePoint {
            ImagePoint(
                x: (camera.fx * point.x / point.z + camera.cx) / Double(imageSize.width),
                y: (camera.fy * point.y / point.z + camera.cy) / Double(imageSize.height)
            )
        }
        let a = Point3D(x: -halfLength * cos(angle), y: 0, z: centreDepth - halfLength * sin(angle))
        let b = Point3D(x: halfLength * cos(angle), y: 0, z: centreDepth + halfLength * sin(angle))
        let sessionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let frameID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let frame = MeasurementFrame(
            sessionID: sessionID,
            frameID: frameID,
            timestamp: 100,
            capturedAt: Date(timeIntervalSince1970: 1_790_100_000),
            imageSize: imageSize,
            intrinsics: camera,
            depth: DepthMap(size: depthSize, values: depth, confidence: .init(repeating: 2, count: depth.count)),
            source: .synthetic,
            orientation: .up
        )
        let landmarks = GarmentLandmarkSet(
            sessionID: sessionID,
            frameID: frameID,
            origin: .synthetic,
            modelVersion: nil,
            points: [
                GarmentLandmark(id: "A", point: project(a), confidence: 1),
                GarmentLandmark(id: "B", point: project(b), confidence: 1)
            ],
            mask: GarmentMask(size: depthSize, values: .init(repeating: 1, count: depth.count))
        )
        return (frame, landmarks, 0.5)
    }
}
