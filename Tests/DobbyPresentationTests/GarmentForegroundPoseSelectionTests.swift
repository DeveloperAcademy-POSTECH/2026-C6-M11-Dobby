import XCTest
@testable import Dobby

/// Injected observations exercise the production provider's selection pipeline.
/// They verify candidate preservation and bounded work, not real model accuracy.
@MainActor
final class GarmentForegroundPoseSelectionTests: XCTestCase {
    private let size = PixelSize(width: 200, height: 160)

    private func topPoints() -> [GarmentLandmark] {
        let positions: [(String, Double, Double)] = [
            ("neck_left", 0.43, 0.11), ("neck_right", 0.57, 0.11),
            ("shoulder_left", 0.3, 0.19), ("shoulder_right", 0.7, 0.19),
            ("armpit_left", 0.3, 0.33), ("armpit_right", 0.7, 0.33),
            ("sleeve_end_left", 0.15, 0.36), ("sleeve_end_right", 0.85, 0.36),
            ("hem_left", 0.3, 0.81), ("hem_center", 0.5, 0.81), ("hem_right", 0.7, 0.81)
        ]
        return positions.map { .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: 0.69) }
    }

    private func partiallyAssociatedPoints() -> [GarmentLandmark] {
        var points = topPoints()
        for index in points.indices where ["neck_left", "neck_right", "sleeve_end_left", "sleeve_end_right"].contains(points[index].id) {
            points[index].point = .init(x: index.isMultiple(of: 2) ? 0.02 : 0.98, y: 0.02)
        }
        points.append(.init(id: "neck_center", point: .init(x: 0.5, y: 0.02), confidence: 0.69,
                            derivedFrom: ["neck_left", "neck_right"]))
        return points
    }

    private func polygon(_ vertices: [ImagePoint]) -> GarmentMask {
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height { for x in 0..<size.width {
            let point = ImagePoint(x: (Double(x) + 0.5) / Double(size.width),
                                   y: (Double(y) + 0.5) / Double(size.height))
            var inside = false
            for index in vertices.indices {
                let a = vertices[index], b = vertices[(index + 1) % vertices.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            if inside { values[y * size.width + x] = 1 }
        } }
        return .init(size: size, values: values)
    }

    private func topMask() -> GarmentMask {
        polygon([
            .init(x: 0.43, y: 0.1), .init(x: 0.3, y: 0.18), .init(x: 0.1, y: 0.3),
            .init(x: 0.18, y: 0.42), .init(x: 0.3, y: 0.33), .init(x: 0.3, y: 0.82),
            .init(x: 0.7, y: 0.82), .init(x: 0.7, y: 0.33), .init(x: 0.82, y: 0.42),
            .init(x: 0.9, y: 0.3), .init(x: 0.7, y: 0.18), .init(x: 0.57, y: 0.1),
            .init(x: 0.5, y: 0.17)
        ])
    }

    private func predict(_ points: [GarmentLandmark]) -> BottomLandmarkPrediction {
        .init(points: points, detectionConfidence: 0.85)
    }

    private func assertUnchanged(_ actual: [GarmentLandmark], _ expected: [GarmentLandmark],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map(\.point), expected.map(\.point), file: file, line: line)
        XCTAssertEqual(actual.map(\.confidence), expected.map(\.confidence), file: file, line: line)
        XCTAssertEqual(actual.map(\.isVisible), expected.map(\.isVisible), file: file, line: line)
        XCTAssertEqual(actual.map(\.derivedFrom), expected.map(\.derivedFrom), file: file, line: line)
    }

    func testStrictSuccessKeepsOriginalDirectionAndRawCandidates() throws {
        let raw = topPoints(), mask = topMask()
        var inferDirections: [ImageOrientation] = [], maskDirections: [ImageOrientation] = []
        let result = try GarmentForegroundPoseSelection.recognize(orientation: .right,
            allowsHalfTurn: true, recordsRecoverableFailures: false, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { inferDirections.append($0); return self.predict(raw) },
            masks: { maskDirections.append($0); return [mask] })
        XCTAssertEqual(inferDirections, [.right])
        XCTAssertEqual(maskDirections, [.right])
        assertUnchanged(result.recognition.points, raw)
        XCTAssertEqual(result.selection.mask, mask)
        let diagnostics = try XCTUnwrap(result.recognition.diagnostics)
        XCTAssertEqual(diagnostics.requestedOrientation, .right)
        XCTAssertEqual(diagnostics.selectedPoseOrientation, .right)
        XCTAssertEqual(diagnostics.associationPolicy, .strict)
        XCTAssertFalse(diagnostics.requiresReview)
    }

    func testOriginalSubjectWinsWithoutRotationOrExtraVisionAndRetainsUnmatchedPoints() throws {
        let raw = partiallyAssociatedPoints(), mask = topMask()
        var inferDirections: [ImageOrientation] = [], maskDirections: [ImageOrientation] = []
        let result = try GarmentForegroundPoseSelection.recognize(orientation: .up,
            allowsHalfTurn: true, recordsRecoverableFailures: false, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { inferDirections.append($0); return self.predict(raw) },
            masks: { maskDirections.append($0); return [mask] })
        XCTAssertEqual(inferDirections, [.up])
        XCTAssertEqual(maskDirections, [.up])
        XCTAssertEqual(result.poseRequests, 1)
        XCTAssertEqual(result.foregroundRequests, 1)
        assertUnchanged(result.recognition.points, raw)
        XCTAssertEqual(result.selection.mask, mask)
        let diagnostics = try XCTUnwrap(result.recognition.diagnostics)
        assertUnchanged(diagnostics.rawPoints, raw)
        XCTAssertEqual(diagnostics.selectedPoseOrientation, .up)
        XCTAssertEqual(diagnostics.associationPolicy, .subject)
        XCTAssertEqual(diagnostics.kindEvidence?.status, .supported)
        XCTAssertTrue(diagnostics.requiresReview)
        XCTAssertEqual(diagnostics.poseAttempts.count, 1)
        XCTAssertEqual(diagnostics.pointAssessments.first { $0.landmarkID == "neck_left" }?.status, .outsideMask)
        XCTAssertEqual(diagnostics.pointAssessments.first { $0.landmarkID == "neck_center" }?.status, .derived)
    }

    func testExactOrientationSubjectNeverRunsHalfTurn() throws {
        var directions: [ImageOrientation] = []
        let result = try GarmentForegroundPoseSelection.recognize(orientation: .left,
            allowsHalfTurn: false, recordsRecoverableFailures: true, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { directions.append($0); return self.predict(self.partiallyAssociatedPoints()) },
            masks: { _ in [self.topMask()] })
        XCTAssertEqual(directions, [.left])
        XCTAssertEqual(result.recognition.diagnostics?.selectedPoseOrientation, .left)
    }

    func testUnusableOriginalAllowsOneHalfTurnAndRecordsBothRawAttempts() throws {
        let rotated = topPoints()
        var original = rotated
        for index in original.indices { original[index].point = .init(x: 0.98, y: 0.98) }
        var directions: [ImageOrientation] = []
        let result = try GarmentForegroundPoseSelection.recognize(orientation: .up,
            allowsHalfTurn: true, recordsRecoverableFailures: false, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { directions.append($0); return self.predict($0 == .up ? original : rotated) },
            masks: { _ in [self.topMask()] })
        XCTAssertEqual(directions, [.up, .down])
        XCTAssertEqual(result.poseRequests, 2)
        XCTAssertEqual(result.foregroundRequests, 2)
        assertUnchanged(result.recognition.points, rotated)
        let diagnostics = try XCTUnwrap(result.recognition.diagnostics)
        XCTAssertEqual(diagnostics.requestedOrientation, .up)
        XCTAssertEqual(diagnostics.selectedPoseOrientation, .down)
        XCTAssertEqual(diagnostics.poseAttempts.map(\.orientation), [.up, .down])
        assertUnchanged(try XCTUnwrap(diagnostics.poseAttempts.first?.rawPoints), original)
        XCTAssertEqual(diagnostics.poseAttempts.first?.failure, "unmatchedForeground")
    }

    func testSubjectAssociationAloneCannotAcceptGenericRectangle() throws {
        let rectangle = polygon([.init(x: 0.29, y: 0.18), .init(x: 0.71, y: 0.18),
                                 .init(x: 0.71, y: 0.82), .init(x: 0.29, y: 0.82)])
        let raw = partiallyAssociatedPoints()
        var directions: [ImageOrientation] = []
        XCTAssertThrowsError(try GarmentForegroundPoseSelection.recognize(orientation: .up,
            allowsHalfTurn: false, recordsRecoverableFailures: true, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { directions.append($0); return self.predict(raw) }, masks: { _ in [rectangle] })) { error in
                guard let diagnosed = error as? GarmentForegroundValidationFailure else {
                    return XCTFail("Expected a recoverable exact-orientation rejection: \(error)")
                }
                XCTAssertEqual(diagnosed.diagnosisCode, "unmatchedForeground")
                XCTAssertEqual(diagnosed.attempts.count, 1)
                guard let candidates = diagnosed.attempts.first?.rawPoints else {
                    return XCTFail("Rejected raw candidates must remain available")
                }
                assertUnchanged(candidates, raw)
                XCTAssertEqual(diagnosed.attempts.first?.failure, "unsupportedPoseStructure")
            }
        XCTAssertEqual(directions, [.up])
    }

    func testExactFailurePreservesRawCandidatesAndOriginalExplanation() throws {
        var raw = topPoints()
        for index in raw.indices { raw[index].point = .init(x: 0.98, y: 0.98) }
        XCTAssertThrowsError(try GarmentForegroundPoseSelection.recognize(orientation: .right,
            allowsHalfTurn: false, recordsRecoverableFailures: true, imageSize: size,
            schemaKind: .top, modelVersion: "fixture-top",
            infer: { _ in self.predict(raw) }, masks: { _ in [self.topMask()] })) { error in
                guard let diagnosed = error as? GarmentForegroundValidationFailure else {
                    return XCTFail("Expected failed attempt diagnostics: \(error)")
                }
                XCTAssertEqual(diagnosed.originalError as? GarmentMaskAssociationError, .unmatchedGarment)
                XCTAssertEqual(diagnosed.errorDescription, GarmentMaskAssociationError.unmatchedGarment.localizedDescription)
                XCTAssertEqual(diagnosed.automaticMeasurementFailureCode, .providerFailure)
                XCTAssertEqual(diagnosed.attempts.map(\.orientation), [.right])
                guard let candidates = diagnosed.attempts.first?.rawPoints else {
                    return XCTFail("Failed raw candidates must remain available")
                }
                assertUnchanged(candidates, raw)
            }
    }

    func testHardErrorsAreNotWrappedOrRetried() {
        for error in [GarmentMaskAssociationError.multipleForegrounds as Error,
                      GarmentMaskAssociationError.invalidMask, BottomModelError.incompatibleModel,
                      CancellationError()] {
            var directions: [ImageOrientation] = []
            XCTAssertThrowsError(try GarmentForegroundPoseSelection.recognize(orientation: .up,
                allowsHalfTurn: true, recordsRecoverableFailures: true, imageSize: size,
                schemaKind: .top, modelVersion: "fixture-top",
                infer: { directions.append($0); throw error }, masks: { _ in [] })) { actual in
                    XCTAssertNil(actual as? GarmentForegroundValidationFailure)
                    XCTAssertEqual(String(reflecting: actual), String(reflecting: error))
                }
            XCTAssertEqual(directions, [.up])
        }
    }
}
