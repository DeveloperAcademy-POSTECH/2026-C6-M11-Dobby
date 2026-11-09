import Foundation
import XCTest
@testable import DobbyLiDARCore

final class TopSideNeckLengthTests: XCTestCase {
    private func scene(orientation: ImageOrientation = .up,
                       normal: Point3D = .init(x: 0, y: 0, z: 1),
                       maskAt: (Double, Double) -> Bool = { $0 >= 0.2 && $0 < 0.8 && $1 >= 0.15 && $1 < 0.85 })
        -> (MeasurementFrame, GarmentLandmarkSet) {
        let size = PixelSize(width: 100, height: 100), session = UUID(), frameID = UUID()
        let frame = MeasurementFrame(sessionID: session, frameID: frameID, timestamp: 1,
            capturedAt: .distantPast, imageSize: size,
            intrinsics: .init(fx: 100, fy: 100, cx: 50, cy: 50, referenceSize: size),
            depth: .init(size: size, values: (0..<10000).map { index in
                Float(1 / (normal.x * (Double(index % 100) / 100 - 0.5)
                    + normal.y * (Double(index / 100) / 100 - 0.5) + normal.z))
            },
                         confidence: Array(repeating: 2, count: 10000)), source: .synthetic, orientation: .up)
        let mask = GarmentMask(size: size, values: (0..<10000).map { index in
            let p = ImageCoordinateTransform.originalToDisplay(
                .init(x: Double(index % 100) / 100, y: Double(index / 100) / 100), orientation: orientation)
            return maskAt(p.x, p.y) ? 1 : 0
        })
        let locations: [(String, Double, Double)] = [
            ("neck_left", 0.35, 0.25), ("neck_right", 0.65, 0.25),
            ("shoulder_left", 0.25, 0.3), ("shoulder_right", 0.75, 0.3),
            ("armpit_left", 0.25, 0.45), ("armpit_right", 0.75, 0.45),
            ("sleeve_end_left", 0.22, 0.65), ("sleeve_end_right", 0.78, 0.65),
            ("hem_left", 0.21, 0.8), ("hem_center", 0.5, 0.83), ("hem_right", 0.79, 0.8),
            ("top_length_start", 0.5, 0.3)]
        let points = locations.map { id, x, y in
            GarmentLandmark(id: id, point: ImageCoordinateTransform.displayToOriginal(
                .init(x: x, y: y), orientation: orientation), confidence: 0.95)
        }
        let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: .up,
            selectedPoseOrientation: orientation, associationPolicy: .subject,
            rawPoints: points, pointAssessments: [], poseAttempts: [], remoteView: "front",
            totalLengthConvention: GarmentLandmarkModelContract.frontGapConvention)
        let landmarks = GarmentLandmarkSet(sessionID: session, frameID: frameID, origin: .model,
            modelVersion: GarmentLandmarkModelContract.lunaGapLengthVersion, points: points,
            mask: mask, garmentKind: .top, recognitionDiagnostics: diagnostics)
        return (frame, TopSideNeckLength.applying(to: landmarks))
    }

    private func calculate(_ frame: MeasurementFrame, _ landmarks: GarmentLandmarkSet) -> GarmentMeasurementResult {
        GarmentPlaneMeasurementEngine().measure(frame: frame, landmarks: landmarks,
            definitions: TopLandmarkSchema.sideNeckMeasurementDefinitions)
    }

    private func total(_ result: GarmentMeasurementResult) throws -> MeasurementValue {
        try XCTUnwrap(result.values.first { $0.id == "top.totalLength" })
    }

    func testUprightVerticalHemAndMetricLengthAcrossAllRotations() throws {
        for orientation in ImageOrientation.allCases {
            let (frame, landmarks) = scene(orientation: orientation)
            let value = try total(calculate(frame, landmarks))
            XCTAssertEqual(value.status, .uncertain, "Remote subject observations retain their review status")
            XCTAssertEqual(try XCTUnwrap(value.meters), 0.6, accuracy: 0.012)
            let endpoint = try XCTUnwrap(value.points.first { $0.id == TopSideNeckLength.hemID })
            let upright = ImageCoordinateTransform.originalToDisplay(endpoint.imagePoint, orientation: orientation)
            XCTAssertEqual(upright.x, 0.35, accuracy: 1e-9)
            XCTAssertEqual(upright.y, 0.85, accuracy: 0.012)
            XCTAssertEqual(endpoint.quality.method, .contourIntersection)
            XCTAssertEqual(endpoint.sourceLandmarkIDs, ["neck_left"])
            XCTAssertNotEqual(endpoint.imagePoint, landmarks.points.first { $0.id == "hem_center" }?.point)
            let mask = try XCTUnwrap(landmarks.mask)
            XCTAssertEqual(mask.values[Int(endpoint.imagePoint.y * 100) * 100 + Int(endpoint.imagePoint.x * 100)], 1)
        }
    }

    func testMissingOldTotalCentersAndRightNeckDoNotBlockNewLengthOrOtherMeasurements() throws {
        let (frame, source) = scene()
        var landmarks = source
        for index in landmarks.points.indices where ["top_length_start", "hem_center", "neck_right"].contains(landmarks.points[index].id) {
            landmarks.points[index].isVisible = false
        }
        let result = calculate(frame, landmarks)
        XCTAssertEqual(result.algorithmVersion, GarmentPlaneMeasurementEngine.sideNeckAlgorithmVersion)
        XCTAssertTrue(result.values.allSatisfy { $0.meters != nil })
        XCTAssertEqual(try XCTUnwrap(total(result).meters), 0.6, accuracy: 0.012)
        let old = GarmentPlaneMeasurementEngine().measure(frame: frame, landmarks: source,
            definitions: TopLandmarkSchema.canonicalMeasurementDefinitions)
        for value in result.values where value.id != "top.totalLength" {
            XCTAssertEqual(value.meters, old.values.first { $0.id == value.id }?.meters)
        }
    }

    func testTiltedPlaneUsesMetricRayIntersectionsInsteadOfImagePixelDistance() throws {
        let normal = Point3D(x: 0.2, y: -0.3, z: 1)
        let (frame, landmarks) = scene(normal: normal)
        let measured = try total(calculate(frame, landmarks))
        let end = try XCTUnwrap(measured.points.last)
        func position(_ x: Double, _ y: Double) -> Point3D {
            let z = 1 / (normal.x * (x - 0.5) + normal.y * (y - 0.5) + normal.z)
            return .init(x: (x - 0.5) * z, y: (y - 0.5) * z, z: z)
        }
        let a = position(0.35, 0.25), b = position(0.35, end.imagePoint.y)
        let expected = hypot(hypot(a.x - b.x, a.y - b.y), a.z - b.z)
        XCTAssertEqual(try XCTUnwrap(measured.meters), expected, accuracy: 0.00001)
        XCTAssertEqual(end.imagePoint.x, 0.35, accuracy: 1e-9)
        XCTAssertEqual(end.imagePoint.y, 0.85, accuracy: 0.012)
    }

    func testImageClippingCannotBecomeAFalseHem() throws {
        let (frame, landmarks) = scene(maskAt: { x, y in x >= 0.2 && x < 0.8 && y >= 0.15 })
        let result = calculate(frame, landmarks)
        XCTAssertNil(try total(result).meters)
        XCTAssertEqual(try total(result).failure, .contourIntersectionUnavailable)
        XCTAssertTrue(result.values.filter { $0.id != "top.totalLength" }.allSatisfy { $0.meters != nil })
    }

    func testClosedMaskHoleIsSkippedButEarlyExteriorGapFailsOnlyLength() throws {
        let (frame, closed) = scene(maskAt: { x, y in
            x >= 0.2 && x < 0.8 && y >= 0.15 && y < 0.85
                && !(x > 0.32 && x < 0.38 && y > 0.45 && y < 0.53)
        })
        XCTAssertEqual(try XCTUnwrap(total(calculate(frame, closed)).meters), 0.6, accuracy: 0.012)
        let (gapFrame, open) = scene(maskAt: { x, y in
            x >= 0.2 && x < 0.8 && y >= 0.15 && y < 0.85
                && !(x < 0.4 && y > 0.45 && y < 0.53)
        })
        let result = calculate(gapFrame, open)
        XCTAssertNil(try total(result).meters)
        XCTAssertEqual(try total(result).failure, .contourIntersectionUnavailable)
        XCTAssertTrue(result.values.filter { $0.id != "top.totalLength" }.allSatisfy { $0.meters != nil })
    }

    func testMissingLeftNeckNeverSwitchesSidesAndKeepsEditablePendingHandles() throws {
        let (frame, source) = scene()
        var landmarks = source
        landmarks.points[0].isVisible = false
        let result = calculate(frame, landmarks)
        XCTAssertNil(try total(result).meters)
        XCTAssertEqual(try total(result).failure, .occludedLandmark)
        let model = automatic(frame, landmarks, result)
        XCTAssertTrue(model.canCorrectTotalLength)
        XCTAssertEqual(model.photoEditingPresentation.pendingIDs, ["neck_left", TopSideNeckLength.hemID])
        XCTAssertFalse(model.photoEditingPresentation.landmarks.points.contains { $0.id == "top_length_start" })
        XCTAssertFalse(landmarks.points[0].isVisible)
    }

    func testDraggingNeckRecomputesHemAndArchiveResetPreservesAutomaticEvidence() throws {
        let (frame, landmarks) = scene(maskAt: { x, y in
            x >= 0.2 && x < 0.8 && y >= 0.15 && y < (x < 0.4 ? 0.8 : 0.9)
        })
        let original = calculate(frame, landmarks)
        var model = automatic(frame, landmarks, original)
        XCTAssertTrue(model.visibleEditableLandmarks.points.contains { $0.id == "neck_left" })
        XCTAssertTrue(model.visibleEditableLandmarks.points.contains { $0.id == TopSideNeckLength.hemID && $0.isVisible })
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.45, y: 0.25), id: "neck_left"))
        let derived = try XCTUnwrap(model.calculationLandmarks.points.first { $0.id == TopSideNeckLength.hemID })
        XCTAssertEqual(derived.contourRule, .leftNeckVerticalHemMaskV1)
        XCTAssertEqual(derived.origin, .manual)
        let recalculated = calculate(frame, model.calculationLandmarks)
        XCTAssertTrue(model.apply(recalculated, for: model.calculationRevision))
        let endpoint = try XCTUnwrap(total(recalculated).points.last)
        XCTAssertEqual(endpoint.imagePoint.x, 0.45, accuracy: 1e-9)
        XCTAssertEqual(endpoint.imagePoint.y, 0.9, accuracy: 0.012)
        let record = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(model.makeRecord()))
        XCTAssertEqual(record.landmarks.recognitionDiagnostics?.totalLengthConvention, GarmentLandmarkModelContract.sideNeckConvention)
        XCTAssertEqual(record.originalAutomaticLandmarks?.points[0].point, landmarks.points[0].point)
        var reopened = AutomaticMeasurement(record: record)
        reopened.resetPointAdjustments()
        XCTAssertEqual(reopened.calculationLandmarks.points[0].point, landmarks.points[0].point)
        XCTAssertEqual(try total(calculate(frame, reopened.calculationLandmarks)).meters, try total(original).meters)
    }

    private func automatic(_ frame: MeasurementFrame, _ landmarks: GarmentLandmarkSet,
                           _ result: GarmentMeasurementResult) -> AutomaticMeasurement {
        .init(output: .init(runID: UUID(), snapshot: .init(frame: frame, imageJPEG: Data()),
            landmarks: landmarks, result: result, definitions: TopLandmarkSchema.sideNeckMeasurementDefinitions,
            options: .init(calculationMode: .garmentPlane),
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .distantPast, finishedAt: .distantPast))
    }
}
