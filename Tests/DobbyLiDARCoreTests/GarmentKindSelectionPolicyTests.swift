import Foundation
import XCTest
@testable import DobbyLiDARCore

final class GarmentKindSelectionPolicyTests: XCTestCase {
    private let size = PixelSize(width: 200, height: 160)
    private let topPolygon: [ImagePoint] = [
        .init(x: 0.43, y: 0.1), .init(x: 0.3, y: 0.18), .init(x: 0.1, y: 0.3),
        .init(x: 0.18, y: 0.42), .init(x: 0.3, y: 0.33), .init(x: 0.3, y: 0.82),
        .init(x: 0.7, y: 0.82), .init(x: 0.7, y: 0.33), .init(x: 0.82, y: 0.42),
        .init(x: 0.9, y: 0.3), .init(x: 0.7, y: 0.18), .init(x: 0.57, y: 0.1),
        .init(x: 0.5, y: 0.17)
    ]

    private func topPoints(confidence: Double = 0.9) -> [GarmentLandmark] {
        let positions: [(String, Double, Double)] = [
            ("neck_left", 0.43, 0.11), ("neck_right", 0.57, 0.11),
            ("shoulder_left", 0.3, 0.19), ("shoulder_right", 0.7, 0.19),
            ("armpit_left", 0.3, 0.33), ("armpit_right", 0.7, 0.33),
            ("sleeve_end_left", 0.15, 0.36), ("sleeve_end_right", 0.85, 0.36),
            ("hem_left", 0.3, 0.81), ("hem_center", 0.5, 0.81), ("hem_right", 0.7, 0.81)
        ]
        return positions.map { .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: confidence) }
    }

    private func bottomPoints(confidence: Double = 0.9) -> [GarmentLandmark] {
        let positions: [(String, Double, Double)] = [
            ("waist_left", 0.25, 0.15), ("waist_right", 0.75, 0.15), ("crotch", 0.5, 0.45),
            ("hem_left_outer", 0.2, 0.85), ("hem_left_inner", 0.4, 0.85),
            ("hem_right_inner", 0.6, 0.85), ("hem_right_outer", 0.8, 0.85)
        ]
        return positions.map { .init(id: $0.0, point: .init(x: $0.1, y: $0.2), confidence: confidence) }
    }

    private func bottomMask() -> GarmentMask {
        polygon([
            .init(x: 0.25, y: 0.15), .init(x: 0.75, y: 0.15), .init(x: 0.8, y: 0.86),
            .init(x: 0.6, y: 0.86), .init(x: 0.5, y: 0.45), .init(x: 0.4, y: 0.86),
            .init(x: 0.2, y: 0.86)
        ])
    }

    private func polygon(_ points: [ImagePoint]) -> GarmentMask {
        var values = [UInt8](repeating: 0, count: size.width * size.height)
        for y in 0..<size.height { for x in 0..<size.width {
            let p = ImagePoint(x: (Double(x) + 0.5) / Double(size.width),
                               y: (Double(y) + 0.5) / Double(size.height))
            var inside = false
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            if inside { values[y * size.width + x] = 1 }
        } }
        return .init(size: size, values: values)
    }

    private func evidence(_ kind: AutomaticGarmentKind, _ points: [GarmentLandmark], _ mask: GarmentMask) throws -> GarmentKindEvidence {
        let selection = try GarmentMaskAssociation.select(masks: [mask], points: points,
            imageSize: mask.size, policy: .subject)
        return GarmentKindSelectionPolicy.evaluate(kind: kind, points: points,
                                                   selection: selection, imageSize: mask.size)
    }

    func testTopRequiresPoseBodyAndIndependentSleeveTorsoSilhouette() throws {
        let result = try evidence(.top, topPoints(), polygon(topPolygon))
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertEqual(result.reasons, [.solidTorso, .pairedSleeveBranches])
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: result, bottoms: nil), .selected(.top))
    }

    func testPantsRequireBothLegForegroundAndTheActualGapBelowCrotch() throws {
        let result = try evidence(.bottoms, bottomPoints(), bottomMask())
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertEqual(result.reasons, [.separatedLegs])
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: nil, bottoms: result), .selected(.bottoms))
    }

    func testBottom8RecognizesDirectFrontCenterWithoutMakingItAClassGate() throws {
        let points = bottomPoints()
        let front = GarmentLandmark(id: "waist_front_center", point: .init(x: 0.5, y: 0.2), confidence: 0.92)
        let complete = try evidence(.bottoms, points + [front], bottomMask())
        XCTAssertEqual(complete.status, .supported)
        XCTAssertEqual(complete.metrics["semanticDirectPoints"], 8)
        let missing = try evidence(.bottoms, points, bottomMask())
        XCTAssertEqual(missing.status, .supported, "Only the rise measurement depends on the eighth point")
        var uncertainFront = front
        uncertainFront.confidence = 0.49
        let partial = try evidence(.bottoms, points + [uncertainFront], bottomMask())
        XCTAssertEqual(partial.status, .supported)
        XCTAssertEqual(partial.metrics["semanticDirectPoints"], 7, "Existing 0.5 confidence threshold stays intact")
    }

    func testPartialTopWithoutNeckSleevesOrHemCenterStillClassifiesBody() throws {
        let points = topPoints().filter { ["shoulder_left", "shoulder_right", "armpit_left", "armpit_right", "hem_left", "hem_right"].contains($0.id) }
        let result = try evidence(.top, points, polygon(topPolygon))
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertEqual(result.metrics["associatedDirectPoints"], 6)
    }

    func testFourActualBodyAnchorsCanIdentifyTopWithoutInventingSleevePoints() throws {
        let ids: Set<String> = ["armpit_left", "armpit_right", "hem_left", "hem_right"]
        let points = topPoints().filter { ids.contains($0.id) }
        let before = points
        let result = try evidence(.top, points, polygon(topPolygon))
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertEqual(result.metrics["semanticDirectPoints"], 4)
        XCTAssertEqual(result.metrics["associatedBodyPoints"], 4)
        XCTAssertEqual(points.map(\.id), before.map(\.id))
        XCTAssertEqual(points.map(\.point), before.map(\.point))
        XCTAssertFalse(points.contains { $0.id.hasPrefix("sleeve_end") })
    }

    func testZeroPointSixNineAndZeroPointSevenHaveSameIdentityWithIndependentShapeEvidence() throws {
        for kind in AutomaticGarmentKind.allCases {
            let mask = kind == .top ? polygon(topPolygon) : bottomMask()
            let first = kind == .top ? topPoints(confidence: 0.69) : bottomPoints(confidence: 0.69)
            let second = kind == .top ? topPoints(confidence: 0.70) : bottomPoints(confidence: 0.70)
            let belowFormerGate = try evidence(kind, first, mask)
            let atFormerGate = try evidence(kind, second, mask)
            XCTAssertEqual(belowFormerGate.status, .supported, "\(kind): \(belowFormerGate)")
            XCTAssertEqual(atFormerGate.status, belowFormerGate.status)
            XCTAssertEqual(atFormerGate.reasons, belowFormerGate.reasons)
            XCTAssertEqual(belowFormerGate.metrics["strongDirectPoints"], 0,
                           "The former 0.7 threshold is diagnostic, not a class requirement.")
        }
    }

    func testUndersegmentedBoundaryKeepsRawHemAndBodyIdentityButDoesNotInventDepth() throws {
        let points = topPoints()
        var mask = polygon(topPolygon)
        // The real hem point remains outside the imperfect mask by more than
        // association tolerance. Other body anchors and sleeve shape identify
        // the same top; the hole must never be dilated for depth measurement.
        for y in 124...134 { for x in 55...65 { mask.values[y * size.width + x] = 0 } }
        let before = mask
        let selection = try GarmentMaskAssociation.select(masks: [mask], points: points,
            imageSize: size, policy: .subject)
        XCTAssertEqual(selection.pointAssessments.first { $0.landmarkID == "hem_left" }?.status, .outsideMask)
        XCTAssertEqual(selection.validatedPoints(points).map(\.point), points.map(\.point))
        XCTAssertEqual(selection.validatedPoints(points).map(\.isVisible), points.map(\.isVisible))
        XCTAssertEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points,
            selection: selection, imageSize: size).status, .supported)
        let frame = MeasurementFrame(sessionID: UUID(), frameID: UUID(), timestamp: 1, capturedAt: .now,
            imageSize: size, intrinsics: .init(fx: 200, fy: 200, cx: 100, cy: 80, referenceSize: size),
            depth: .init(size: size, values: .init(repeating: 1.2, count: size.width * size.height),
                         confidence: .init(repeating: 2, count: size.width * size.height)),
            source: .synthetic, orientation: .up)
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .model, modelVersion: "top-mask-preservation-test", points: selection.validatedPoints(points), mask: mask)
        let definition = MeasurementDefinition(id: "top.hemWidth", title: "밑단", landmarkIDs: ["hem_left", "hem_right"])
        let value = try XCTUnwrap(LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks,
            definitions: [definition]).values.first)
        XCTAssertEqual(value.status, .unavailable)
        XCTAssertNil(value.meters)
        XCTAssertEqual(selection.mask, before)
    }

    func testPartialBodySilhouetteNeedsIndependentSleevesAndRetainsUnknownOrRejectedBands() throws {
        let points = topPoints()
        let probes: [(Int, Int)] = [(100, 79), (100, 102), (100, 118), (88, 79), (112, 79), (76, 79), (124, 79)]
        for (removed, expected) in [(3, GarmentKindEvidenceStatus.supported), (4, .uncertain), (7, .rejected)] {
            var mask = polygon(topPolygon)
            for (x, y) in probes.prefix(removed) {
                for row in (y - 3)...(y + 3) {
                    for column in (x - 3)...(x + 3) { mask.values[row * size.width + column] = 0 }
                }
            }
            let before = mask
            let result = try evidence(.top, points, mask)
            XCTAssertEqual(result.status, expected, "removed \(removed): \(result)")
            if removed == 3 {
                XCTAssertEqual(result.reasons, [.partialSilhouette, .pairedSleeveBranches])
                XCTAssertEqual(result.metrics["torsoForegroundFraction"], 0.8)
            }
            XCTAssertEqual(mask, before)
            XCTAssertEqual(points.map(\.point), topPoints().map(\.point))
        }
    }

    func testHighConfidenceTopPoseInsideGenericRectangleDoesNotProveSleeves() throws {
        let mask = polygon([.init(x: 0.08, y: 0.08), .init(x: 0.92, y: 0.08),
                            .init(x: 0.92, y: 0.9), .init(x: 0.08, y: 0.9)])
        let result = try evidence(.top, topPoints(confidence: 1), mask)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.unsupportedSilhouette])
    }

    func testHighConfidenceBottomPoseInsideSolidSkirtOrRectangleIsRejected() throws {
        let mask = polygon([.init(x: 0.15, y: 0.1), .init(x: 0.85, y: 0.1),
                            .init(x: 0.85, y: 0.9), .init(x: 0.15, y: 0.9)])
        let result = try evidence(.bottoms, bottomPoints(confidence: 1), mask)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.unsupportedSilhouette])
    }

    func testClosedInternalHoleCannotMasqueradeAsLegCorridorOpenTowardHem() throws {
        var mask = polygon([.init(x: 0.15, y: 0.1), .init(x: 0.85, y: 0.1),
                            .init(x: 0.85, y: 0.9), .init(x: 0.15, y: 0.9)])
        for y in 80..<104 { for x in 90..<110 { mask.values[y * size.width + x] = 0 } }
        let before = mask
        let result = try evidence(.bottoms, bottomPoints(), mask)
        XCTAssertGreaterThan(result.metrics["separatedLegRows", default: 0], 2)
        XCTAssertEqual(result.metrics["exteriorLegGapRows"], 0)
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.reasons, [.unsupportedSilhouette])
        XCTAssertEqual(mask, before)
    }

    func testTwoCompatibleModelsStayAmbiguousRegardlessOfTheirConfidenceOrdering() throws {
        let top = try evidence(.top, topPoints(confidence: 0.71), polygon(topPolygon))
        let bottom = try evidence(.bottoms, bottomPoints(confidence: 0.99), bottomMask())
        XCTAssertEqual(top.status, .supported)
        XCTAssertEqual(bottom.status, .supported)
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: top, bottoms: bottom), .ambiguous)
    }

    func testSupportedAndUncertainIsAmbiguousAndMissingBothIsNoDetection() throws {
        let top = try evidence(.top, topPoints(), polygon(topPolygon))
        let weak = GarmentKindEvidence(kind: .bottoms, status: .uncertain, reasons: [.insufficientSemanticSupport])
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: top, bottoms: weak), .ambiguous)
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: nil, bottoms: nil), .noDetection)
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: .unmatched(kind: .top), bottoms: nil), .noDetection)
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: top, bottoms: .unmatched(kind: .bottoms)), .selected(.top))
    }

    func testAllFourRawOrientationsRetainIndependentShapeEvidence() throws {
        for kind in AutomaticGarmentKind.allCases {
            let sourceMask = kind == .top ? polygon(topPolygon) : bottomMask()
            let sourcePoints = kind == .top ? topPoints() : bottomPoints()
            for orientation in [ImageOrientation.up, .right, .down, .left] {
                let mask = try GarmentMaskOrientation.originalMask(fromUpright: sourceMask, orientation: orientation)
                let points = sourcePoints.map { landmark -> GarmentLandmark in
                    var value = landmark
                    value.point = ImageCoordinateTransform.displayToOriginal(landmark.point, orientation: orientation)
                    return value
                }
                XCTAssertEqual(try evidence(kind, points, mask).status, .supported, "\(kind) \(orientation)")
            }
        }
    }

    func testConfidenceBelowMeasurementThresholdOrDerivedBodyAnchorsCannotEstablishAClass() throws {
        var points = topPoints()
        for i in points.indices where ["hem_left", "hem_right"].contains(points[i].id) {
            points[i].confidence = 0.49
        }
        // Other observed points can associate the subject, but cannot replace
        // missing usable direct body anchors with invented geometry.
        let mask = polygon(topPolygon)
        let selection = try GarmentMaskAssociation.select(masks: [mask], points: points, imageSize: size)
        XCTAssertEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points,
            selection: selection, imageSize: size).status, .uncertain)
        points = topPoints()
        points[points.firstIndex { $0.id == "hem_left" }!].derivedFrom = ["shoulder_left", "armpit_left"]
        points[points.firstIndex { $0.id == "hem_center" }!].derivedFrom = ["hem_left", "hem_right"]
        let selection2 = try GarmentMaskAssociation.select(masks: [mask], points: points, imageSize: size)
        XCTAssertEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points,
            selection: selection2, imageSize: size).status, .uncertain)
    }

    func testMissingHemEndpointCanClassifyWithoutCreatingAMeasurementPoint() throws {
        let points = topPoints().filter { $0.id != "hem_left" }
        let before = points
        let mask = polygon(topPolygon)
        let result = try evidence(.top, points, mask)
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertEqual(points.map(\.id), before.map(\.id))
        XCTAssertEqual(points.map(\.point), before.map(\.point))
        XCTAssertEqual(points.map(\.confidence), before.map(\.confidence))
        XCTAssertEqual(points.map(\.isVisible), before.map(\.isVisible))
        XCTAssertFalse(points.contains { $0.id == "hem_left" })
    }

    func testOneMissingBottomEndpointRetainsActualTwoLegEvidence() throws {
        for id in ["hem_left_inner", "hem_right_outer"] {
            let points = bottomPoints().filter { $0.id != id }
            XCTAssertEqual(try evidence(.bottoms, points, bottomMask()).status, .supported, id)
            XCTAssertFalse(points.contains { $0.id == id })
        }
    }

    func testSparseRivalPoseIsRejectedAndDoesNotVetoSupportedClass() throws {
        let top = try evidence(.top, topPoints(), polygon(topPolygon))
        let points = bottomPoints().filter { ["waist_left", "crotch", "hem_left_outer", "hem_left_inner"].contains($0.id) }
        let bottom = try evidence(.bottoms, points, bottomMask())
        XCTAssertEqual(bottom.status, .rejected)
        XCTAssertEqual(bottom.reasons, [.insufficientSemanticSupport])
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: top, bottoms: bottom), .selected(.top))
    }

    func testDownwardSleevesMayBeSeparatedBelowBodyHemInsteadOfBesideBody() throws {
        let mask = polygon([
            .init(x: 0.43, y: 0.1), .init(x: 0.26, y: 0.18), .init(x: 0.12, y: 0.87),
            .init(x: 0.22, y: 0.9), .init(x: 0.3, y: 0.75), .init(x: 0.7, y: 0.75),
            .init(x: 0.78, y: 0.9), .init(x: 0.88, y: 0.87), .init(x: 0.74, y: 0.18),
            .init(x: 0.57, y: 0.1), .init(x: 0.5, y: 0.17)
        ])
        var points = topPoints()
        for i in points.indices {
            switch points[i].id {
            case "hem_left", "hem_center", "hem_right": points[i].point.y = 0.74
            case "sleeve_end_left": points[i].point = .init(x: 0.17, y: 0.86)
            case "sleeve_end_right": points[i].point = .init(x: 0.83, y: 0.86)
            default: break
            }
        }
        let result = try evidence(.top, points, mask)
        XCTAssertEqual(result.status, .supported, "\(result)")
        XCTAssertGreaterThanOrEqual(result.metrics["lowerPairedSleeveRows", default: 0], 2)
    }

    func testMalformedMaskAndDuplicatePointIDsAreUncertainWithoutMutation() throws {
        let points = topPoints(), mask = polygon(topPolygon)
        var selection = try GarmentMaskAssociation.select(masks: [mask], points: points, imageSize: size)
        selection.mask.values.removeLast()
        XCTAssertEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points,
            selection: selection, imageSize: size).reasons, [.invalidInput])
        selection.mask = mask
        XCTAssertEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points + [points[0]],
            selection: selection, imageSize: size).reasons, [.invalidInput])
        XCTAssertEqual(selection.mask, mask)
        XCTAssertEqual(points.count, 11)
    }

    func testImageEdgeAndNearEdgePointsFailSafelyAndCannotInventSupport() throws {
        let original = topPoints(), mask = polygon(topPolygon)
        let selection = try GarmentMaskAssociation.select(masks: [mask], points: original, imageSize: size)
        for coordinate in [1.0, 1.0.nextDown, 0.0, Double.nan] {
            var points = original
            for i in points.indices where ["hem_left", "hem_right"].contains(points[i].id) {
                points[i].point = .init(x: coordinate, y: coordinate)
            }
            XCTAssertNotEqual(GarmentKindSelectionPolicy.evaluate(kind: .top, points: points,
                selection: selection, imageSize: size).status, .supported)
        }
    }

    func testSelectionRejectsSwappedEvidenceSlotsAndDiagnosticsRoundTrip() throws {
        let top = try evidence(.top, topPoints(), polygon(topPolygon))
        XCTAssertEqual(GarmentKindSelectionPolicy.select(top: nil, bottoms: top), .ambiguous)
        let restored = try JSONDecoder().decode(GarmentKindEvidence.self, from: JSONEncoder().encode(top))
        XCTAssertEqual(restored.kind, top.kind)
        XCTAssertEqual(restored.status, top.status)
        XCTAssertEqual(restored.metrics, top.metrics)
        let selection = GarmentKindSelection.selected(.top)
        XCTAssertEqual(try JSONDecoder().decode(GarmentKindSelection.self,
            from: JSONEncoder().encode(selection)), selection)
    }
}
