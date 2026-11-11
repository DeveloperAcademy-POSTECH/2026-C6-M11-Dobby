import XCTest
@testable import DobbyLiDARCore

final class GarmentEditingPointPresentationTests: XCTestCase {
    private func snapshot(orientation: ImageOrientation) -> CaptureSnapshot {
        let size = PixelSize(width: 100, height: 80)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .distantPast,
            imageSize: size, intrinsics: .init(fx: 100, fy: 100, cx: 50, cy: 40, referenceSize: size),
            depth: .init(size: size, values: Array(repeating: 1, count: 8000)), source: .synthetic, orientation: orientation)
        return .init(frame: frame, imageJPEG: Data())
    }

    func testNeckHintKeepsRawCoordinatesAcrossAllInferenceAndDisplayRotations() throws {
        for upright in ImageOrientation.allCases {
            for display in ImageOrientation.allCases {
                let snapshot = snapshot(orientation: display)
                func raw(_ p: ImagePoint) -> ImagePoint {
                    ImageCoordinateTransform.displayToOriginal(p, orientation: upright)
                }
                let points: [GarmentLandmark] = [
                    .init(id: "neck_left", point: raw(.init(x: 0.4, y: 0.2))),
                    .init(id: "neck_right", point: raw(.init(x: 0.6, y: 0.2))),
                    .init(id: "top_length_start", point: .init(x: 0.5, y: 0.5), isVisible: false)]
                let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: upright, selectedPoseOrientation: upright,
                    associationPolicy: .subject, rawPoints: points, pointAssessments: [], poseAttempts: [])
                let source = GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
                    origin: .model, points: points, recognitionDiagnostics: diagnostics)
                let shown = GarmentEditingPointPresentation.make(displayed: source, source: source, snapshot: snapshot)
                let actual = try XCTUnwrap(shown.landmarks.points.last?.point)
                let expected = raw(.init(x: 0.5, y: 0.2))
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
                XCTAssertEqual(shown.pendingIDs, ["top_length_start"])
                XCTAssertFalse(source.points.last!.isVisible)
            }
        }
    }

    func testOutsideViewportCandidateIsOnlyClampedForItsTemporaryHandle() throws {
        var snapshot = snapshot(orientation: .right)
        snapshot.presentationCrop = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let candidate = GarmentLandmark(id: "hem_center", point: .init(x: 0.95, y: 0.95))
        var unavailable = candidate; unavailable.isVisible = false
        let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: .up, selectedPoseOrientation: .up,
            associationPolicy: .subject, rawPoints: [candidate], pointAssessments: [], poseAttempts: [])
        let source = GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .model, points: [unavailable], recognitionDiagnostics: diagnostics)
        let shown = GarmentEditingPointPresentation.make(displayed: source, source: source, snapshot: snapshot)
        let p = ImageCoordinateTransform.originalToDisplay(shown.landmarks.points[0].point, orientation: .right)
        XCTAssertTrue((0.25...0.75).contains(p.x) && (0.25...0.75).contains(p.y))
        XCTAssertEqual(source.recognitionDiagnostics?.rawPoints[0].point, candidate.point)
        XCTAssertFalse(source.points[0].isVisible)
    }

    func testMissingAnchorsStillProduceSeparateUpperAndLowerDisplayHandles() {
        let snapshot = snapshot(orientation: .up)
        let source = GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
            origin: .model, points: ["top_length_start", "hem_center"].map {
                .init(id: $0, point: .init(x: 0.5, y: 0.5), isVisible: false)
            })
        let shown = GarmentEditingPointPresentation.make(displayed: source, source: source, snapshot: snapshot)
        XCTAssertEqual(shown.pendingIDs.count, 2)
        XCTAssertTrue(shown.landmarks.points.allSatisfy { $0.isVisible && $0.point.isValid && $0.origin != .manual })
        XCTAssertLessThan(shown.landmarks.points[0].point.y, shown.landmarks.points[1].point.y)
    }
    func testPendingSideNeckHemStaysOnBodyMaskWhenSleevesExtendLower() throws {
        for upright in ImageOrientation.allCases {
            for display in ImageOrientation.allCases {
                let snapshot = snapshot(orientation: display)
                var values = [UInt8](repeating: 0, count: 100 * 80)
                // Body ends at row 55; a sleeve extends the global box to 74.
                for y in 10..<56 { for x in 30..<70 { values[y * 100 + x] = 1 } }
                for y in 20..<75 { for x in 10..<30 { values[y * 100 + x] = 1 } }
                let mask = try GarmentMaskOrientation.originalMask(fromUpright:
                    .init(size: .init(width: 100, height: 80), values: values), orientation: upright)
                let neck = ImageCoordinateTransform.displayToOriginal(.init(x: 0.4, y: 0.2), orientation: upright)
                let points: [GarmentLandmark] = [
                    .init(id: "neck_left", point: neck),
                    .init(id: TopSideNeckLength.hemID, point: .init(x: 0.5, y: 0.5),
                          isVisible: false, contourRule: .leftNeckVerticalHemMaskV1)]
                let diagnostics = GarmentRecognitionDiagnostics(requestedOrientation: upright, selectedPoseOrientation: upright,
                    associationPolicy: .subject, rawPoints: points, pointAssessments: [], poseAttempts: [])
                let source = GarmentLandmarkSet(sessionID: snapshot.frame.sessionID, frameID: snapshot.frame.frameID,
                    origin: .model, points: points, mask: mask, recognitionDiagnostics: diagnostics)
                let shown = GarmentEditingPointPresentation.make(displayed: source, source: source, snapshot: snapshot)
                let actual = try XCTUnwrap(shown.landmarks.points.last?.point)
                let point = ImageCoordinateTransform.originalToDisplay(actual, orientation: upright)
                XCTAssertEqual(point.x, 0.4, accuracy: 0.000001)
                XCTAssertEqual(point.y, 55.5 / 80, accuracy: 0.000001)
                let pixel = Int(actual.y * Double(mask.size.height)) * mask.size.width + Int(actual.x * Double(mask.size.width))
                XCTAssertEqual(mask.values[pixel], 1)
                XCTAssertEqual(shown.pendingIDs, [TopSideNeckLength.hemID])
                XCTAssertFalse(source.points.last!.isVisible)
                XCTAssertEqual(source.points.last!.contourRule, .leftNeckVerticalHemMaskV1)
            }
        }
    }

}
