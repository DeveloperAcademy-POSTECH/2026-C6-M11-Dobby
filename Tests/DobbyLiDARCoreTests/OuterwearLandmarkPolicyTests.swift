import Foundation
import XCTest
@testable import DobbyLiDARCore

final class OuterwearLandmarkPolicyTests: XCTestCase {
    private let requestID = "capture-1"
    private let size = PixelSize(width: 100, height: 100)

    private func response() -> OuterwearLandmarkResponse {
        let positions: [(String, Double, Double)] = [
            ("neck_left", 0.45, 0.2), ("neck_right", 0.55, 0.2),
            ("shoulder_left", 0.3, 0.25), ("shoulder_right", 0.7, 0.25),
            ("armpit_left", 0.3, 0.4), ("armpit_right", 0.7, 0.4),
            ("sleeve_end_left", 0.21, 0.6), ("sleeve_end_right", 0.79, 0.6),
            ("hem_left", 0.3, 0.85), ("hem_center", 0.5, 0.85), ("hem_right", 0.7, 0.85)
        ]
        return .init(requestID: requestID, view: .back, neckStyle: .hood,
            points: Dictionary(uniqueKeysWithValues: positions.map {
                ($0.0, .init(point: .init(x: $0.1, y: $0.2), visibility: .visible))
            }), backNeckSeamCenter: .init(point: .init(x: 0.5, y: 0.23), visibility: .visible))
    }

    private func viewLengthResponse(view: OuterwearLandmarkView = .front) -> OuterwearLandmarkResponse {
        var response = response()
        response.schemaVersion = OuterwearLandmarkResponse.expectedViewLengthSchemaVersion
        response.modelVersion = OuterwearLandmarkResponse.expectedViewLengthModelVersion
        response.view = view
        response.frontNeckSeamCenter = .init(point: .init(x: 0.5, y: 0.28), visibility: .visible)
        return response
    }

    private func mask() -> GarmentMask {
        var values = [UInt8](repeating: 0, count: 10_000)
        for y in 10..<90 { for x in 20..<80 { values[y * 100 + x] = 1 } }
        return .init(size: size, values: values)
    }

    private func frontOnlyResponse() -> OuterwearLandmarkResponse {
        var wire = viewLengthResponse()
        wire.schemaVersion = OuterwearLandmarkResponse.expectedFrontLengthSchemaVersion
        wire.modelVersion = OuterwearLandmarkResponse.expectedFrontLengthModelVersion
        wire.backNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        return wire
    }

    func testV3FrontSeamIsTheSingleCanonicalTotalLengthStart() throws {
        let wire = frontOnlyResponse()
        let result = try evaluate(wire)
        XCTAssertEqual(result.points.map(\.id), TopLandmarkSchema.expectedKeypoints + ["top_length_start"])
        let start = try XCTUnwrap(result.points.last)
        XCTAssertEqual(start.point, wire.frontNeckSeamCenter?.point)
        XCTAssertTrue(start.isVisible)
        XCTAssertNil(start.contourRule)
        XCTAssertEqual(TopLandmarkSchema.canonicalMeasurementDefinitions.last?.id, "top.totalLength")
        XCTAssertTrue(GarmentLandmarkModelContract.isCurrent(version: wire.modelVersion, kind: .top))
        XCTAssertFalse(GarmentLandmarkModelContract.isCurrent(version: wire.modelVersion, kind: .bottoms))
    }

    func testSingleSurvivingNeckSideCannotRejectSupportedCenterSeam() throws {
        for missing in ["neck_left", "neck_right"] {
            var wire = frontOnlyResponse()
            wire.points["neck_left"]?.point = .init(x: 0.38, y: 0.2)
            wire.points["neck_right"]?.point = .init(x: 0.62, y: 0.2)
            wire.points[missing] = .init(point: nil, visibility: .uncertain)
            let result = try evaluate(wire)
            XCTAssertTrue(try XCTUnwrap(result.points.last).isVisible,
                "Both shoulders bound the seam when the neck pair is incomplete")
            wire.frontNeckSeamCenter?.point = .init(x: 0.79, y: 0.28)
            XCTAssertFalse(try XCTUnwrap(evaluate(wire).points.last).isVisible)
        }
    }

    private func nearHemResponse() -> OuterwearLandmarkResponse {
        var wire = frontOnlyResponse()
        wire.points["hem_left"]?.point = .init(x: 0.3, y: 0.89)
        wire.points["hem_right"]?.point = .init(x: 0.7, y: 0.89)
        wire.points["hem_center"]?.point = .init(x: 0.5, y: 0.91)
        return wire
    }

    func testNearbyObservedPointsSnapInRawRectangularSpaceForEveryRotation() throws {
        var wire = frontOnlyResponse()
        let outside: [(String, Double, Double)] = [
            ("shoulder_left", 0.195, 0.255), ("shoulder_right", 0.805, 0.255),
            ("sleeve_end_left", 0.195, 0.605), ("sleeve_end_right", 0.805, 0.605),
            ("hem_left", 0.195, 0.855), ("hem_right", 0.805, 0.855)
        ]
        for (id, x, y) in outside { wire.points[id]?.point = .init(x: x, y: y) }
        // A rectangular raster catches distances or transforms that wrongly
        // treat normalized x/y as having the same pixel scale.
        let square = mask()
        let upright = GarmentMask(size: .init(width: 200, height: 100),
            values: square.values.flatMap { [$0, $0] })
        for orientation in ImageOrientation.allCases {
            let rawMask = try GarmentMaskOrientation.originalMask(fromUpright: upright, orientation: orientation)
            let imageSize = PixelSize(width: rawMask.size.width * 6, height: rawMask.size.height * 6)
            let result = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: requestID,
                imageSize: imageSize, masks: [rawMask], orientation: orientation)
            XCTAssertTrue(result.points.allSatisfy(\.isVisible))
            XCTAssertEqual(result.selection.mask, rawMask)
            XCTAssertEqual(result.selection.matchedLandmarkCount, result.points.count)
            let changes = try XCTUnwrap(result.diagnostics.automaticAdjustments)
            XCTAssertEqual(Set(changes.map(\.landmarkID)), Set(outside.map { $0.0 }))
            for (id, x, y) in outside {
                let point = try XCTUnwrap(result.points.first { $0.id == id })
                let raw = try XCTUnwrap(result.diagnostics.rawPoints.first { $0.id == id })
                let expected = ImageCoordinateTransform.displayToOriginal(
                    .init(x: x < 0.5 ? 0.2025 : 0.7975, y: y), orientation: orientation)
                XCTAssertEqual(point.point.x, expected.x, accuracy: 1e-12)
                XCTAssertEqual(point.point.y, expected.y, accuracy: 1e-12)
                XCTAssertEqual(raw.point, ImageCoordinateTransform.displayToOriginal(.init(x: x, y: y), orientation: orientation))
                XCTAssertNil(point.confidence)
                XCTAssertNotEqual(point.origin, .manual)
                XCTAssertEqual(result.diagnostics.pointAssessments.first { $0.landmarkID == id }?.status, .outsideMask)
                let change = try XCTUnwrap(changes.first { $0.landmarkID == id })
                XCTAssertEqual(change.originalPoint, raw.point)
                XCTAssertEqual(change.adjustedPoint, point.point)
                XCTAssertEqual(change.distancePixels, 9, accuracy: 1e-10)
                XCTAssertEqual(change.method, "mask-nearest-3pct-v1")
            }
            for point in result.points where !changes.contains(where: { $0.landmarkID == point.id }) {
                XCTAssertEqual(point.point, result.diagnostics.rawPoints.first { $0.id == point.id }?.point)
            }
            let reopened = try JSONDecoder().decode(GarmentRecognitionDiagnostics.self,
                from: JSONEncoder().encode(result.diagnostics))
            XCTAssertEqual(reopened.automaticAdjustments, changes)
        }
    }

    func testVisibleFrontSeamNearMaskSnapsAndStillPassesNeckGeometry() throws {
        let wire = frontOnlyResponse()
        var seamMask = mask()
        seamMask.values[28 * 100 + 50] = 0
        let result = try evaluate(wire, masks: [seamMask])
        let seam = try XCTUnwrap(result.points.first { $0.id == "top_length_start" })
        XCTAssertTrue(seam.isVisible)
        XCTAssertEqual(seamMask.values[Int(seam.point.y * 100) * 100 + Int(seam.point.x * 100)], 1)
        XCTAssertEqual(result.diagnostics.rawPoints.last?.point, wire.frontNeckSeamCenter?.point)
        XCTAssertEqual(result.diagnostics.automaticAdjustments?.map(\.landmarkID), [seam.id])
        XCTAssertTrue(result.selection.associatedLandmarkIDs.contains(seam.id))
    }

    func testOutlineSnapPreservesFarNullAndSemanticallyRejectedObservations() throws {
        var wire = frontOnlyResponse()
        wire.points["shoulder_left"]?.point = .init(x: 0.1, y: 0.25)
        wire.points["sleeve_end_right"] = .init(point: nil, visibility: .occluded)
        // Close enough to the side silhouette to snap, but not a neck center.
        wire.frontNeckSeamCenter?.point = .init(x: 0.81, y: 0.28)
        let result = try evaluate(wire)
        for id in ["shoulder_left", "sleeve_end_right", "top_length_start"] {
            let point = try XCTUnwrap(result.points.first { $0.id == id })
            XCTAssertFalse(point.isVisible)
            XCTAssertEqual(point.point, result.diagnostics.rawPoints.first { $0.id == id }?.point)
            XCTAssertFalse(result.selection.associatedLandmarkIDs.contains(id))
        }
        XCTAssertTrue(result.diagnostics.automaticAdjustments?.isEmpty ?? true)
        XCTAssertTrue(result.points.first { $0.id == "shoulder_right" }!.isVisible)
    }

    func testNearHemUsesContinuousBodyBoundaryAndPreservesAIObservationForAllRotations() throws {
        for orientation in ImageOrientation.allCases {
            let wire = nearHemResponse()
            let rawMask = try GarmentMaskOrientation.originalMask(fromUpright: mask(), orientation: orientation)
            let result = try evaluate(wire, masks: [rawMask], orientation: orientation)
            let hem = try XCTUnwrap(result.points.first { $0.id == "hem_center" })
            let expected = ImageCoordinateTransform.displayToOriginal(.init(x: 0.5, y: 0.895), orientation: orientation)
            XCTAssertTrue(hem.isVisible)
            XCTAssertEqual(hem.point, expected)
            XCTAssertNil(hem.confidence)
            XCTAssertNotEqual(hem.origin, .manual)
            let raw = try XCTUnwrap(result.diagnostics.rawPoints.first { $0.id == hem.id })
            XCTAssertEqual(raw.point, ImageCoordinateTransform.displayToOriginal(.init(x: 0.5, y: 0.91), orientation: orientation))
            XCTAssertEqual(result.diagnostics.pointAssessments.first { $0.landmarkID == hem.id }?.status, .outsideMask)
            XCTAssertEqual(result.selection.mask, rawMask)
            XCTAssertTrue(result.selection.associatedLandmarkIDs.contains(hem.id))
            let correction = try XCTUnwrap(result.diagnostics.automaticAdjustments?.first)
            XCTAssertEqual(correction.originalPoint, raw.point)
            XCTAssertEqual(correction.adjustedPoint, expected)
            XCTAssertEqual(correction.distancePixels, 1.5, accuracy: 1e-10)
            XCTAssertEqual(correction.limitPixels, 2, accuracy: 1e-10)
            XCTAssertEqual(correction.method, OuterwearHemBoundaryRefinement.method)
        }
    }

    func testHemRecoveryDoesNotDependOnTotalLengthStartBeingAvailable() throws {
        var wire = nearHemResponse()
        wire.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        let result = try evaluate(wire)
        XCTAssertTrue(try XCTUnwrap(result.points.first { $0.id == "hem_center" }).isVisible)
        XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == "top_length_start" }).isVisible)
    }

    func testHemRecoveryCannotFillNullOrMoveDistantInteriorOrLegacyPoints() throws {
        var null = nearHemResponse()
        null.points["hem_center"] = .init(point: nil, visibility: .uncertain)
        var far = nearHemResponse()
        far.points["hem_center"]?.point = .init(x: 0.5, y: 0.96)
        var interior = nearHemResponse()
        interior.points["hem_center"]?.point = .init(x: 0.5, y: 0.5)
        var legacy = response()
        legacy.points["hem_center"]?.point = .init(x: 0.5, y: 0.91)
        for wire in [null, far, interior, legacy] {
            let result = try evaluate(wire)
            XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == "hem_center" }).isVisible)
            XCTAssertNil(result.diagnostics.automaticAdjustments)
        }
        var supported = nearHemResponse()
        supported.points["hem_center"]?.point = .init(x: 0.5, y: 0.89)
        let result = try evaluate(supported)
        XCTAssertEqual(result.points.first { $0.id == "hem_center" }?.point, .init(x: 0.5, y: 0.89))
        XCTAssertNil(result.diagnostics.automaticAdjustments)
    }

    func testHemRecoveryDoesNotBridgeOpenFrontHoleNotchOrClippedBoundary() throws {
        for shape in ["openFront", "hole", "notch", "clipped"] {
            var altered = mask()
            switch shape {
            case "openFront": for y in 10..<90 { altered.values[y * 100 + 50] = 0 }
            case "hole": for y in 65..<70 { altered.values[y * 100 + 50] = 0 }
            case "notch": for y in 85..<90 { altered.values[y * 100 + 50] = 0 }
            default: for y in 90..<100 { for x in 20..<80 { altered.values[y * 100 + x] = 1 } }
            }
            let result = try evaluate(nearHemResponse(), masks: [altered])
            XCTAssertFalse(result.diagnostics.automaticAdjustments?.contains { $0.landmarkID == "hem_center" } ?? false, shape)
            if shape != "clipped" {
                XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == "hem_center" }).isVisible, shape)
            }
        }
    }

    func testHemRecoveryNeedsIndependentBodyAndSideHemSupport() throws {
        for missing in [["armpit_left"], ["armpit_right"], ["hem_left", "hem_right"]] {
            var wire = nearHemResponse()
            for id in missing { wire.points[id] = .init(point: nil, visibility: .uncertain) }
            let result = try evaluate(wire)
            XCTAssertNil(result.diagnostics.automaticAdjustments)
            XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == "hem_center" }).isVisible)
        }
        var wire = nearHemResponse()
        wire.points["hem_center"]?.point = .init(x: 0.21, y: 0.91)
        XCTAssertNil(try evaluate(wire).diagnostics.automaticAdjustments)
    }

    func testV3MissingFrontSeamKeepsOtherDimensionsAndNeverCreatesRearSlot() throws {
        for view in [OuterwearLandmarkView.front, .back, .unknown] {
            var wire = frontOnlyResponse()
            wire.view = view
            wire.frontNeckSeamCenter = .init(point: nil, visibility: view == .front ? .occluded : .uncertain)
            let result = try evaluate(wire)
            XCTAssertFalse(try XCTUnwrap(result.points.last).isVisible)
            XCTAssertEqual(result.points.filter(\.isVisible).count, 11)
            XCTAssertEqual(Set(OuterwearComparisonGeometry.observations(wire).keys),
                Set(TopLandmarkSchema.expectedKeypoints + ["top_length_start"]))
        }
    }

    func testV3CanonicalStartUsesFrontNeckBoundsAndStrictMask() throws {
        for (coordinate, visible) in [(ImagePoint(x: 0.5, y: 0.37), true),
            (.init(x: 0.5, y: 0.4), false), (.init(x: 0.81, y: 0.28), false)] {
            var wire = frontOnlyResponse()
            wire.frontNeckSeamCenter = .init(point: coordinate, visibility: .visible)
            let result = try evaluate(wire)
            XCTAssertEqual(result.points.last?.isVisible, visible)
            XCTAssertEqual(result.points.last?.point, coordinate)
        }
    }

    func testV3WireAndComparisonTransformPreserveFrontOnlyProvenance() throws {
        let wire = frontOnlyResponse()
        let data = try JSONEncoder().encode(wire)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["backNeckSeamCenter"])
        let restored = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: data)
        try restored.validate(expectedRequestID: requestID)
        let crop = OuterwearComparisonCrop(region: .garment, rect: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.6))
        let mapped = try OuterwearComparisonGeometry.restoring(restored, crops: [crop])
        XCTAssertEqual(mapped.totalLengthStart.point?.x, 0.5)
        XCTAssertEqual(try XCTUnwrap(mapped.totalLengthStart.point?.y), 0.368, accuracy: 1e-12)
        XCTAssertNil(mapped.backNeckSeamCenter.point)
        var invalid = wire
        invalid.view = .back
        XCTAssertThrowsError(try invalid.validate(expectedRequestID: requestID))
        invalid = wire
        invalid.backNeckSeamCenter = .init(point: .init(x: 0.5, y: 0.2), visibility: .visible)
        XCTAssertThrowsError(try invalid.validate(expectedRequestID: requestID))
    }

    private func evaluate(_ response: OuterwearLandmarkResponse, masks: [GarmentMask]? = nil,
                          orientation: ImageOrientation = .up) throws -> OuterwearLandmarkEvaluation {
        try OuterwearLandmarkPolicy.evaluate(response: response, expectedRequestID: requestID,
            imageSize: size, masks: masks ?? [mask()], orientation: orientation)
    }

    func testRemoteObservationsKeepUnknownConfidenceAndExplicitDirectSeamConvention() throws {
        let result = try evaluate(response())
        XCTAssertEqual(result.points.map(\.id), TopLandmarkSchema.expectedKeypoints + ["top_length_start"])
        XCTAssertTrue(result.points.allSatisfy { $0.confidence == nil && $0.derivedFrom == nil && $0.contourRule == nil })
        XCTAssertTrue(result.points.allSatisfy(\.isVisible))
        XCTAssertTrue(result.requiresReview)
        XCTAssertEqual(result.selection.mask, mask())
        XCTAssertEqual(result.selection.matchedLandmarkCount, 12)
        XCTAssertEqual(result.diagnostics.rawPoints.map(\.point), result.points.map(\.point))
        XCTAssertEqual(result.points.last?.point, response().backNeckSeamCenter.point,
            "The direct back seam stays at its observed position without contour estimation")
    }

    func testFrontAndUnknownViewWithholdOnlyTotalStartAndPreserveRawObservation() throws {
        for view in [OuterwearLandmarkView.front, .unknown] {
            var wire = response()
            wire.view = view
            let result = try evaluate(wire)
            XCTAssertEqual(result.points.filter(\.isVisible).map(\.id), TopLandmarkSchema.expectedKeypoints)
            let start = try XCTUnwrap(result.points.last)
            let raw = try XCTUnwrap(result.diagnostics.rawPoints.last)
            XCTAssertFalse(start.isVisible, "A front hem must not be paired with a back-neck seam")
            XCTAssertTrue(raw.isVisible, "Preserve rejected provider observations for diagnosis")
            XCTAssertEqual(start.point, raw.point)
            XCTAssertNil(start.contourRule)
            XCTAssertFalse(result.selection.associatedLandmarkIDs.contains("top_length_start"))
        }
    }

    func testInteriorOrHighHemDisablesOnlyThatEndpointWithoutMovingIt() throws {
        for y in [0.50, 0.10] {
            var wire = response()
            wire.points["hem_center"] = .init(point: .init(x: 0.5, y: y), visibility: .visible)
            let result = try evaluate(wire)
            let hem = try XCTUnwrap(result.points.first { $0.id == "hem_center" })
            XCTAssertFalse(hem.isVisible)
            XCTAssertEqual(hem.point, .init(x: 0.5, y: y))
            XCTAssertEqual(result.points.filter { !$0.isVisible }.map(\.id), ["hem_center"])
            XCTAssertTrue(result.diagnostics.rawPoints.first { $0.id == "hem_center" }!.isVisible)
            XCTAssertFalse(result.selection.associatedLandmarkIDs.contains("hem_center"))
            XCTAssertTrue(result.points.last!.isVisible, "A bad hem cannot erase a supported back seam")
        }
    }

    func testLocalCurvedHemDoesNotUseLowerSideHemsOrDistantMaterialAsAReplacement() throws {
        var wire = response(), curved = mask()
        wire.points["hem_center"] = .init(point: .init(x: 0.5, y: 0.79), visibility: .visible)
        for y in 80..<90 { for x in 45..<56 { curved.values[y * 100 + x] = 0 } }
        // A lower piece lies on the same column after a background gap. The
        // endpoint remains the local center edge rather than the lowest pixel.
        for y in 95..<100 { for x in 45..<56 { curved.values[y * 100 + x] = 1 } }
        let result = try evaluate(wire, masks: [curved])
        let hem = try XCTUnwrap(result.points.first { $0.id == "hem_center" })
        XCTAssertTrue(hem.isVisible)
        XCTAssertEqual(hem.point, .init(x: 0.5, y: 0.79))
    }

    func testInteriorHemCheckSamplesDownwardInUprightSpaceForEveryRotation() throws {
        var wire = response()
        wire.points["hem_center"] = .init(point: .init(x: 0.5, y: 0.5), visibility: .visible)
        for orientation in ImageOrientation.allCases {
            let rotated = try GarmentMaskOrientation.originalMask(fromUpright: mask(), orientation: orientation)
            let result = try evaluate(wire, masks: [rotated], orientation: orientation)
            XCTAssertFalse(result.points.first { $0.id == "hem_center" }!.isVisible)
            XCTAssertTrue(result.points.first { $0.id == "hem_left" }!.isVisible)
            XCTAssertEqual(result.diagnostics.rawPoints.first { $0.id == "hem_center" }!.point,
                ImageCoordinateTransform.displayToOriginal(.init(x: 0.5, y: 0.5), orientation: orientation))
        }
    }

    func testImplausibleSeamIsWithheldWithoutErasingElevenBodyObservations() throws {
        for point in [ImagePoint(x: 0.5, y: 0.84), .init(x: 0.5, y: 0.88),
                      .init(x: 0.75, y: 0.23), .init(x: 0.5, y: 0.11)] {
            var wire = response()
            wire.backNeckSeamCenter = .init(point: point, visibility: .visible)
            let result = try evaluate(wire)
            XCTAssertEqual(result.points.filter(\.isVisible).map(\.id), TopLandmarkSchema.expectedKeypoints)
            XCTAssertFalse(result.points.last!.isVisible)
            XCTAssertTrue(result.diagnostics.rawPoints.last!.isVisible)
            XCTAssertEqual(result.points.last!.point, point)
            XCTAssertFalse(result.selection.associatedLandmarkIDs.contains("top_length_start"))
        }
    }

    func testUnavailableSeamRetainsOtherDimensionsWithoutGuessingStart() throws {
        var wire = response()
        wire.backNeckSeamCenter = .init(point: nil, visibility: .occluded)
        let result = try evaluate(wire)
        let start = try XCTUnwrap(result.points.first { $0.id == "top_length_start" })
        XCTAssertFalse(start.isVisible)
        XCTAssertTrue(start.point.isValid)
        XCTAssertNil(start.confidence)
        XCTAssertNil(start.contourRule, "Do not replace an unseen seam with the old outer-contour convention")
        XCTAssertEqual(result.points.filter(\.isVisible).count, 11)
        XCTAssertEqual(result.diagnostics.pointAssessments.last?.status, .notVisible)
    }

    func testOutsideHemIsNotClampedAndDoesNotEraseSupportedPoints() throws {
        var wire = response()
        wire.points["hem_center"] = .init(point: .init(x: 0.5, y: 0.96), visibility: .visible)
        let result = try evaluate(wire)
        let hem = try XCTUnwrap(result.points.first { $0.id == "hem_center" })
        XCTAssertEqual(hem.point, .init(x: 0.5, y: 0.96))
        XCTAssertFalse(hem.isVisible)
        let rawHem = try XCTUnwrap(result.diagnostics.rawPoints.first { $0.id == "hem_center" })
        XCTAssertTrue(rawHem.isVisible)
        XCTAssertEqual(rawHem.point, hem.point)
        XCTAssertEqual(result.diagnostics.pointAssessments.first { $0.landmarkID == "hem_center" }?.status, .outsideMask)
        XCTAssertTrue(result.points.first { $0.id == "armpit_left" }?.isVisible == true)
        XCTAssertTrue(result.points.first { $0.id == "hem_left" }?.isVisible == true)
        XCTAssertEqual(result.selection.mask, mask())
    }

    func testSeamOutsideMaterialIsUnavailableEvenWhenModelClaimsVisible() throws {
        var wire = response()
        wire.backNeckSeamCenter = .init(point: .init(x: 0.5, y: 0.05), visibility: .visible)
        let result = try evaluate(wire)
        XCTAssertFalse(try XCTUnwrap(result.points.last).isVisible)
        XCTAssertEqual(result.diagnostics.pointAssessments.last?.status, .outsideMask)
    }

    func testPartialUpperBodyCanRemainUsableWhenHemsAreUnavailable() throws {
        var wire = response()
        for id in ["hem_left", "hem_center", "hem_right"] {
            wire.points[id] = .init(point: nil, visibility: .uncertain)
        }
        let result = try evaluate(wire)
        XCTAssertEqual(result.points.filter(\.isVisible).count, 9)
        XCTAssertEqual(result.selection.matchedLandmarkCount, 9)
    }

    func testAllFourUploadOrientationsRestoreRawCoordinatesExactlyOnce() throws {
        let full = GarmentMask(size: size, values: .init(repeating: 1, count: 10_000))
        let wire = response()
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let result = try evaluate(wire, masks: [full], orientation: orientation)
            for point in result.diagnostics.rawPoints {
                let uploaded = point.id == "top_length_start" ? wire.backNeckSeamCenter.point : wire.points[point.id]?.point
                XCTAssertEqual(point.point, ImageCoordinateTransform.displayToOriginal(try XCTUnwrap(uploaded), orientation: orientation))
            }
            XCTAssertEqual(result.diagnostics.selectedPoseOrientation, orientation)
        }
    }

    func testRejectsNoMaterialSupportClutterMalformedMaskAndCrossedBody() throws {
        let empty = GarmentMask(size: size, values: .init(repeating: 0, count: 10_000))
        XCTAssertThrowsError(try evaluate(response(), masks: [empty])) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .noForeground)
        }
        XCTAssertThrowsError(try evaluate(response(), masks: [mask(), mask()])) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .multipleForegrounds)
        }
        var invalid = mask()
        invalid.values[0] = 2
        XCTAssertThrowsError(try evaluate(response(), masks: [invalid])) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .invalidMask)
        }
        var distant = mask()
        for index in distant.values.indices { distant.values[index] = index % 100 < 10 ? 1 : 0 }
        XCTAssertThrowsError(try evaluate(response(), masks: [distant])) {
            XCTAssertEqual($0 as? OuterwearLandmarkError, .unsupportedGeometry)
        }
        var crossed = response()
        crossed.points["shoulder_left"] = .init(point: .init(x: 0.75, y: 0.25), visibility: .visible)
        XCTAssertThrowsError(try evaluate(crossed)) {
            XCTAssertEqual($0 as? OuterwearLandmarkError, .unsupportedGeometry)
        }
    }

    func testResponseRejectsUntrustedVersionsRequestIDsAndPointInventories() throws {
        var wire = response()
        wire.requestID = "another-frame"
        XCTAssertThrowsError(try wire.validate(expectedRequestID: requestID)) {
            XCTAssertEqual($0 as? OuterwearLandmarkError, .mismatchedRequest)
        }
        for property in ["schema", "version", "model", "missing", "extra"] {
            wire = response()
            switch property {
            case "schema": wire.schemaVersion = "future"
            case "version": wire.modelVersion = "top11-sleeveouter-62f220dae7f3"
            case "model": wire.model = "untrusted"
            case "missing": wire.points.removeValue(forKey: "hem_center")
            default: wire.points["unexpected"] = .init(point: nil, visibility: .uncertain)
            }
            XCTAssertThrowsError(try wire.validate(expectedRequestID: requestID))
        }
    }

    func testResponseRejectsInvalidVisibleCoordinatesAndNonNullHiddenPoints() throws {
        for point in [ImagePoint(x: .nan, y: 0.5), .init(x: .infinity, y: 0.5),
                      .init(x: -0.01, y: 0.5), .init(x: 1, y: 0.5)] {
            var wire = response()
            wire.points["hem_center"] = .init(point: point, visibility: .visible)
            XCTAssertThrowsError(try wire.validate(expectedRequestID: requestID))
        }
        var wire = response()
        wire.points["hem_center"] = .init(point: nil, visibility: .visible)
        XCTAssertThrowsError(try wire.validate(expectedRequestID: requestID))
        wire.points["hem_center"] = .init(point: .init(x: 0.5, y: 0.8), visibility: .occluded)
        XCTAssertThrowsError(try wire.validate(expectedRequestID: requestID))
    }

    func testStrictWireDecodingRejectsExtraAndMissingFieldsAtEveryLevel() throws {
        let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response())) as! [String: Any]
        for modification in 0..<6 {
            var object = valid
            switch modification {
            case 0: object["invented"] = true
            case 1: object.removeValue(forKey: "backNeckSeamCenter")
            case 2: object["view"] = "sideways"
            case 3: object["backNeckSeamCenter"] = ["point": ["x": 0.5, "y": 0.2], "visibility": "visible", "confidence": 0.99]
            case 4: object["backNeckSeamCenter"] = ["point": ["x": 0.5, "y": 0.2, "z": 1], "visibility": "visible"]
            default: object["backNeckSeamCenter"] = ["visibility": "uncertain"]
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: data))
        }
        var wire = response()
        wire.backNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        let encoded = try JSONEncoder().encode(wire)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertTrue((object["backNeckSeamCenter"] as? [String: Any])?["point"] is NSNull)
        let decoded = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: encoded)
        XCTAssertNoThrow(try decoded.validate(expectedRequestID: requestID))
    }

    func testV2FaceSpecificLengthStartsNeverMixAcrossFrontBackOrUnknownViews() throws {
        for view in [OuterwearLandmarkView.front, .back, .unknown] {
            let wire = viewLengthResponse(view: view)
            let result = try evaluate(wire)
            XCTAssertEqual(result.points.map(\.id), TopLandmarkSchema.expectedKeypoints
                + [OuterwearLandmarkPolicy.totalLengthStartID, OuterwearLandmarkPolicy.frontLengthStartID])
            let back = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.totalLengthStartID })
            let front = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
            XCTAssertEqual(back.isVisible, view == .back)
            XCTAssertEqual(front.isVisible, view == .front)
            XCTAssertEqual(back.point, wire.backNeckSeamCenter.point)
            XCTAssertEqual(front.point, wire.frontNeckSeamCenter?.point)
            XCTAssertTrue(result.points.first { $0.id == "hem_center" }?.isVisible == true)
            XCTAssertTrue(result.points.allSatisfy { $0.confidence == nil && $0.derivedFrom == nil && $0.contourRule == nil })
            XCTAssertTrue(result.requiresReview)
            for id in [OuterwearLandmarkPolicy.totalLengthStartID, OuterwearLandmarkPolicy.frontLengthStartID] {
                XCTAssertTrue(result.diagnostics.rawPoints.first { $0.id == id }?.isVisible == true,
                    "A face mismatch withholds measurement use without erasing the original observation")
            }
            XCTAssertEqual(result.selection.associatedLandmarkIDs.contains(back.id), view == .back)
            XCTAssertEqual(result.selection.associatedLandmarkIDs.contains(front.id), view == .front)
        }
    }

    func testV2NullFrontSeamDoesNotBorrowVisibleBackSeamOrHideOtherDimensions() throws {
        var wire = viewLengthResponse()
        wire.frontNeckSeamCenter = .init(point: nil, visibility: .occluded)
        let result = try evaluate(wire)
        XCTAssertEqual(result.points.filter(\.isVisible).count, 11)
        let front = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
        XCTAssertFalse(front.isVisible)
        XCTAssertTrue(front.point.isValid)
        XCTAssertNil(front.confidence)
        XCTAssertNil(front.contourRule)
        XCTAssertTrue(result.points.first { $0.id == "shoulder_left" }?.isVisible == true)
        XCTAssertTrue(result.points.first { $0.id == "hem_center" }?.isVisible == true)
        XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.totalLengthStartID }).isVisible)
    }

    func testV2FrontSeamUsesSameStrictMaterialAndNeckGeometryChecks() throws {
        for coordinate in [ImagePoint(x: 0.5, y: 0.05), .init(x: 0.81, y: 0.28), .init(x: 0.5, y: 0.6)] {
            var wire = viewLengthResponse()
            wire.frontNeckSeamCenter = .init(point: coordinate, visibility: .visible)
            let result = try evaluate(wire)
            let front = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
            XCTAssertFalse(front.isVisible)
            XCTAssertEqual(front.point, coordinate, "A rejected seam is never moved onto another garment edge")
            XCTAssertEqual(result.points.prefix(11).filter(\.isVisible).count, 11)
            XCTAssertEqual(result.diagnostics.rawPoints.first { $0.id == front.id }?.point, coordinate)
        }
    }

    func testV2LowerVisibleFrontNeckSeamUsesObservedArmpitBoundWithoutMovingPoint() throws {
        var wire = viewLengthResponse()
        let lowerAttachment = ImagePoint(x: 0.5, y: 0.37)
        wire.frontNeckSeamCenter = .init(point: lowerAttachment, visibility: .visible)
        let result = try evaluate(wire)
        let start = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
        XCTAssertTrue(start.isVisible, "A visible V-neck seam may be lower than the side-neck and shoulder band")
        XCTAssertEqual(start.point, lowerAttachment)
        XCTAssertEqual(result.diagnostics.rawPoints.first { $0.id == start.id }?.point, lowerAttachment)
        XCTAssertEqual(result.points.prefix(11).filter(\.isVisible).count, 11)

        wire.view = .back
        wire.backNeckSeamCenter = .init(point: lowerAttachment, visibility: .visible)
        let back = try evaluate(wire)
        XCTAssertFalse(try XCTUnwrap(back.points.first { $0.id == OuterwearLandmarkPolicy.totalLengthStartID }).isVisible,
            "The front-only low neckline bound must never loosen back-seam validation")
    }

    func testV2FrontSeamAtOrBelowSupportedArmpitIsRejectedAsBodyInterior() throws {
        for y in [0.4, 0.45] {
            var wire = viewLengthResponse()
            let interior = ImagePoint(x: 0.5, y: y)
            wire.frontNeckSeamCenter = .init(point: interior, visibility: .visible)
            let result = try evaluate(wire)
            let start = try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
            XCTAssertFalse(start.isVisible)
            XCTAssertEqual(start.point, interior)
            XCTAssertTrue(result.points.first { $0.id == "hem_center" }?.isVisible == true)
        }
    }

    func testV2LowerFrontSeamStillRequiresMaterialSupportedArmpitEvidence() throws {
        for mode in ["absent", "near", "far"] {
            var wire = viewLengthResponse()
            wire.frontNeckSeamCenter = .init(point: .init(x: 0.5, y: 0.37), visibility: .visible)
            for (id, x) in [("armpit_left", mode == "far" ? 0.1 : 0.19),
                            ("armpit_right", mode == "far" ? 0.9 : 0.81)] {
                wire.points[id] = mode == "absent" ? .init(point: nil, visibility: .occluded)
                    : .init(point: .init(x: x, y: 0.4), visibility: .visible)
            }
            let result = try evaluate(wire)
            XCTAssertEqual(try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID }).isVisible,
                mode == "near", "Only accepted, material-supported armpits can bound the front neck region")
        }
    }

    func testV2NearbyShoulderAndCuffUseBoundedSnapAndRetainRawDiagnostics() throws {
        var wire = viewLengthResponse()
        for (id, y) in [("shoulder_right", 0.25), ("sleeve_end_right", 0.6)] {
            wire.points[id] = .init(point: .init(x: 0.805, y: y), visibility: .visible)
        }
        let result = try evaluate(wire)
        for id in ["shoulder_right", "sleeve_end_right"] {
            let point = try XCTUnwrap(result.points.first { $0.id == id })
            XCTAssertTrue(point.isVisible)
            XCTAssertEqual(mask().values[Int(point.point.y * 100) * 100 + Int(point.point.x * 100)], 1)
            XCTAssertEqual(result.diagnostics.rawPoints.first { $0.id == id }?.point, wire.points[id]?.point)
            XCTAssertTrue(result.diagnostics.automaticAdjustments?.contains { $0.landmarkID == id } == true)
            XCTAssertEqual(result.diagnostics.pointAssessments.first { $0.landmarkID == id }?.status, .outsideMask)
        }
        XCTAssertTrue(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID }?.isVisible == true)
    }

    func testV2InteriorHemStillDisablesOnlyHemAndPreservesFaceSpecificStart() throws {
        var wire = viewLengthResponse()
        wire.points["hem_center"] = .init(point: .init(x: 0.5, y: 0.55), visibility: .visible)
        let result = try evaluate(wire)
        XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == "hem_center" }).isVisible)
        XCTAssertEqual(result.points.first { $0.id == "hem_center" }?.point, .init(x: 0.5, y: 0.55))
        XCTAssertTrue(result.points.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID }?.isVisible == true)
        XCTAssertFalse(try XCTUnwrap(result.points.first { $0.id == OuterwearLandmarkPolicy.totalLengthStartID }).isVisible)
    }

    func testV2FrontHelperRestoresOriginalCoordinatesForAllFourOrientations() throws {
        let full = GarmentMask(size: size, values: .init(repeating: 1, count: 10_000))
        let wire = viewLengthResponse()
        let uploaded = try XCTUnwrap(wire.frontNeckSeamCenter?.point)
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let result = try evaluate(wire, masks: [full], orientation: orientation)
            let raw = try XCTUnwrap(result.diagnostics.rawPoints.first { $0.id == OuterwearLandmarkPolicy.frontLengthStartID })
            XCTAssertEqual(raw.point, ImageCoordinateTransform.displayToOriginal(uploaded, orientation: orientation))
            XCTAssertEqual(result.points.count, 13)
        }
    }

    func testVersionedWireKeysPreserveV1AndRequireV2FrontObservation() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let legacyData = try encoder.encode(response())
        let legacyObject = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        XCTAssertNil(legacyObject["frontNeckSeamCenter"])
        let legacy = try decoder.decode(OuterwearLandmarkResponse.self, from: legacyData)
        XCTAssertNoThrow(try legacy.validate(expectedRequestID: requestID))
        XCTAssertNil(legacy.frontNeckSeamCenter)
        XCTAssertEqual(try evaluate(legacy).points.count, 12)

        var wire = viewLengthResponse()
        wire.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        let data = try encoder.encode(wire)
        let valid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = try decoder.decode(OuterwearLandmarkResponse.self, from: data)
        XCTAssertNoThrow(try decoded.validate(expectedRequestID: requestID))
        XCTAssertNotNil(decoded.frontNeckSeamCenter)
        XCTAssertNil(decoded.frontNeckSeamCenter?.point)

        for modification in 0..<7 {
            var object = valid
            switch modification {
            case 0: object.removeValue(forKey: "frontNeckSeamCenter")
            case 1: object["frontNeckSeamCenter"] = NSNull()
            case 2: object["extra"] = true
            case 3: object["frontNeckSeamCenter"] = ["point": NSNull(), "visibility": "uncertain", "confidence": 0.9]
            case 4: object["schemaVersion"] = OuterwearLandmarkResponse.expectedSchemaVersion
            case 5: object["frontNeckSeamCenter"] = ["point": ["x": 0.5, "y": 0.3, "z": 1], "visibility": "visible"]
            default: object["frontNeckSeamCenter"] = ["visibility": "uncertain"]
            }
            XCTAssertThrowsError(try decoder.decode(OuterwearLandmarkResponse.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testV1AndV2SchemaModelPairsAndFrontPointVisibilityRemainExact() throws {
        var legacyWithFront = response()
        legacyWithFront.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        XCTAssertThrowsError(try legacyWithFront.validate(expectedRequestID: requestID))
        var current = viewLengthResponse()
        current.modelVersion = OuterwearLandmarkResponse.expectedModelVersion
        XCTAssertThrowsError(try current.validate(expectedRequestID: requestID))
        current = viewLengthResponse()
        current.frontNeckSeamCenter = nil
        XCTAssertThrowsError(try current.validate(expectedRequestID: requestID))
        for observation in [OuterwearLandmarkObservation(point: .init(x: 1, y: 0.3), visibility: .visible),
                            .init(point: nil, visibility: .visible),
                            .init(point: .init(x: 0.5, y: 0.3), visibility: .uncertain)] {
            current = viewLengthResponse()
            current.frontNeckSeamCenter = observation
            XCTAssertThrowsError(try current.validate(expectedRequestID: requestID))
        }
        XCTAssertEqual(OuterwearLandmarkResponse.expectedModelVersion, GarmentLandmarkModelContract.lunaOuterwearVersion)
        XCTAssertEqual(OuterwearLandmarkResponse.expectedViewLengthModelVersion, GarmentLandmarkModelContract.lunaViewLengthVersion)
        for version in [GarmentLandmarkModelContract.lunaOuterwearVersion, GarmentLandmarkModelContract.lunaViewLengthVersion] {
            XCTAssertTrue(GarmentLandmarkModelContract.isLunaOuterwear(version: version, kind: .top))
            XCTAssertFalse(GarmentLandmarkModelContract.isLunaOuterwear(version: version, kind: .bottoms))
        }
        XCTAssertTrue(GarmentLandmarkModelContract.isViewLengthOuterwear(version: GarmentLandmarkModelContract.lunaViewLengthVersion, kind: .top))
        XCTAssertFalse(GarmentLandmarkModelContract.isViewLengthOuterwear(version: GarmentLandmarkModelContract.lunaOuterwearVersion, kind: .top))
        XCTAssertFalse(GarmentLandmarkModelContract.isLunaOuterwear(version: "luna-outerwear11-view-length-v999", kind: .top))
    }
}
