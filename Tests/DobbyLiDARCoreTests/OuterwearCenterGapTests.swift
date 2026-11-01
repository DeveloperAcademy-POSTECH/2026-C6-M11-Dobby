import XCTest
@testable import DobbyLiDARCore

final class OuterwearCenterGapTests: XCTestCase {
    private func fixture() -> (OuterwearLandmarkResponse, GarmentMask) {
        let points: [(String, Double, Double)] = [
            ("neck_left", 0.4, 0.2), ("neck_right", 0.6, 0.2),
            ("shoulder_left", 0.3, 0.25), ("shoulder_right", 0.7, 0.25),
            ("armpit_left", 0.3, 0.4), ("armpit_right", 0.7, 0.4),
            ("sleeve_end_left", 0.21, 0.6), ("sleeve_end_right", 0.79, 0.6),
            ("hem_left", 0.3, 0.895), ("hem_right", 0.7, 0.895), ("hem_center", 0.5, 0.895)]
        let neck = OuterwearCenterSupport(left: .init(x: 0.47, y: 0.27), right: .init(x: 0.53, y: 0.27))
        let hem = OuterwearCenterSupport(left: .init(x: 0.47, y: 0.895), right: .init(x: 0.53, y: 0.895))
        var response = OuterwearLandmarkResponse(requestID: "gap", schemaVersion: "outerwear-landmarks-v4",
            modelVersion: "luna-outerwear11-front-gap-v4", view: .front, neckStyle: .hood,
            points: Dictionary(uniqueKeysWithValues: points.map { ($0.0, .init(point: .init(x: $0.1, y: $0.2), visibility: .visible)) }),
            frontNeckSeamCenter: .init(point: neck.midpoint, visibility: .estimated),
            centerSupport: .init(frontNeckSeamCenter: neck, hemCenter: hem))
        response.points["hem_center"] = .init(point: hem.midpoint, visibility: .estimated)
        var values = [UInt8](repeating: 0, count: 10000)
        for y in 10..<90 { for x in 20..<80 { values[y * 100 + x] = 1 } }
        for y in 25..<30 { for x in 49...51 { values[y * 100 + x] = 0 } }
        for y in 88..<90 { for x in 49...51 { values[y * 100 + x] = 0 } }
        return (response, .init(size: .init(width: 100, height: 100), values: values))
    }

    func testVirtualCentersRemainInGapAndPreserveSupportsForEveryRotation() throws {
        let (wire, mask) = fixture()
        for orientation in ImageOrientation.allCases {
            let rawMask = try GarmentMaskOrientation.originalMask(fromUpright: mask, orientation: orientation)
            let result = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: "gap",
                imageSize: mask.size, masks: [rawMask], orientation: orientation)
            XCTAssertEqual(result.diagnostics.centerEstimates?.count, 2)
            XCTAssertNil(result.diagnostics.automaticAdjustments)
            for id in ["top_length_start", "hem_center"] {
                let point = try XCTUnwrap(result.points.first { $0.id == id })
                let original = id == "hem_center" ? wire.points[id]!.point! : wire.totalLengthStart.point!
                XCTAssertTrue(point.isVisible)
                XCTAssertEqual(point.point, ImageCoordinateTransform.displayToOriginal(original, orientation: orientation))
                XCTAssertEqual(result.diagnostics.pointAssessments.first { $0.landmarkID == id }?.status, .outsideMask)
            }
            XCTAssertEqual(result.selection.mask, rawMask)
            let reopened = try JSONDecoder().decode(GarmentRecognitionDiagnostics.self,
                from: JSONEncoder().encode(result.diagnostics))
            XCTAssertEqual(reopened.centerEstimates?.count, 2)
        }
    }

    func testMissingNeckStillAllowsIndependentEstimatedHem() throws {
        var (wire, mask) = fixture()
        wire.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain)
        wire.centerSupport?.frontNeckSeamCenter = nil
        let result = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: "gap",
            imageSize: mask.size, masks: [mask], orientation: .up)
        XCTAssertTrue(result.points.first { $0.id == "hem_center" }!.isVisible)
        XCTAssertFalse(result.points.first { $0.id == "top_length_start" }!.isVisible)
    }

    func testShoulderRecoveryKeepsVirtualCentersInGapAndRestoresMeasurements() throws {
        var (wire, mask) = fixture()
        wire.points["shoulder_left"]?.point = .init(x: 0.195, y: 0.255)
        wire.points["shoulder_right"]?.point = .init(x: 0.805, y: 0.255)
        let evaluation = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: "gap",
            imageSize: mask.size, masks: [mask], orientation: .up)
        XCTAssertEqual(Set(evaluation.diagnostics.automaticAdjustments?.map(\.landmarkID) ?? []),
            ["shoulder_left", "shoulder_right"])
        for id in ["top_length_start", "hem_center"] {
            let point = try XCTUnwrap(evaluation.points.first { $0.id == id })
            XCTAssertTrue(point.isVisible)
            XCTAssertEqual(point.point, evaluation.diagnostics.rawPoints.first { $0.id == id }?.point)
            XCTAssertEqual(mask.values[Int(point.point.y * 100) * 100 + Int(point.point.x * 100)], 0)
        }
        let session = UUID(), frameID = UUID()
        let landmarks = GarmentLandmarkSet(sessionID: session, frameID: frameID, origin: .model,
            modelVersion: wire.modelVersion, points: evaluation.points, mask: mask,
            garmentKind: .top, recognitionDiagnostics: evaluation.diagnostics)
        let frame = MeasurementFrame(sessionID: session, frameID: frameID, timestamp: 1, capturedAt: .distantPast,
            imageSize: mask.size, intrinsics: .init(fx: 80, fy: 80, cx: 50, cy: 50, referenceSize: mask.size),
            depth: .init(size: mask.size, values: mask.values.map { $0 == 1 ? 1.2 : 3.0 },
                confidence: Array(repeating: 2, count: 10000)), source: .synthetic, orientation: .up)
        let result = GarmentPlaneMeasurementEngine().measure(frame: frame, landmarks: landmarks,
            definitions: TopLandmarkSchema.canonicalMeasurementDefinitions)
        for id in ["top.shoulderWidth", "top.sleeveLengthLeft", "top.sleeveLengthRight", "top.totalLength"] {
            let value = try XCTUnwrap(result.values.first { $0.id == id })
            XCTAssertTrue(value.hasUsableMeasurement, id)
            XCTAssertEqual(value.status, .uncertain, "Snapping does not manufacture model confidence")
            XCTAssertNil(value.failure)
        }
    }

    func testWideGapUnsupportedEdgesAndInteriorHemCannotBypassMask() throws {
        let (base, mask) = fixture()
        for support in [
            OuterwearCenterSupport(left: .init(x: 0.3, y: 0.895), right: .init(x: 0.7, y: 0.895)),
            .init(left: .init(x: 0.47, y: 0.96), right: .init(x: 0.53, y: 0.96)),
            .init(left: .init(x: 0.47, y: 0.65), right: .init(x: 0.53, y: 0.65)),
            .init(left: .init(x: 0.47, y: 0.8), right: .init(x: 0.53, y: 0.895))
        ] {
            var wire = base
            wire.centerSupport?.hemCenter = support
            wire.points["hem_center"]?.point = support.midpoint
            let result = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: "gap",
                imageSize: mask.size, masks: [mask], orientation: .up)
            XCTAssertFalse(result.points.first { $0.id == "hem_center" }!.isVisible)
            XCTAssertTrue(result.points.first { $0.id == "armpit_left" }!.isVisible)
        }
    }

    func testContractRejectsUnsubstantiatedOrLegacyEstimates() throws {
        let (base, _) = fixture()
        var missing = base; missing.centerSupport?.hemCenter = nil
        var inconsistent = base; inconsistent.points["hem_center"]?.point?.x = 0.51
        var shoulder = base; shoulder.points["shoulder_left"]?.visibility = .estimated
        var legacy = base; legacy.schemaVersion = "outerwear-landmarks-v3"; legacy.modelVersion = "luna-outerwear11-front-length-v3"; legacy.centerSupport = nil
        var back = base; back.view = .back
        for wire in [missing, inconsistent, shoulder, legacy, back] {
            XCTAssertThrowsError(try wire.validate(expectedRequestID: "gap"))
        }
        try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: JSONEncoder().encode(base)).validate(expectedRequestID: "gap")
    }

    func testCropRestoresCentersAndSupportingEdgesTogether() throws {
        let (base, _) = fixture()
        let crop = OuterwearComparisonCrop(region: .garment, rect: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        let restored = try OuterwearComparisonGeometry.restoring(base, crops: [crop])
        try restored.validate(expectedRequestID: "gap")
        XCTAssertEqual(restored.centerSupport!.hemCenter!.left.x, 0.1 + 0.47 * 0.7, accuracy: 1e-12)
        XCTAssertEqual(restored.points["hem_center"]!.point!.y, 0.2 + 0.895 * 0.6, accuracy: 1e-12)
    }

    func testGapDepthNeverReplacesGarmentPlaneAndEstimateRemainsUncertain() throws {
        let (wire, mask) = fixture()
        let evaluation = try OuterwearLandmarkPolicy.evaluate(response: wire, expectedRequestID: "gap",
            imageSize: mask.size, masks: [mask], orientation: .up)
        let session = UUID(), frameID = UUID()
        let landmarks = GarmentLandmarkSet(sessionID: session, frameID: frameID, origin: .model,
            modelVersion: wire.modelVersion, points: evaluation.points, mask: mask,
            garmentKind: .top, recognitionDiagnostics: evaluation.diagnostics)
        for background: Float in [0, 1.8, 3.0] {
            let frame = MeasurementFrame(sessionID: session, frameID: frameID, timestamp: 1, capturedAt: .distantPast,
                imageSize: mask.size, intrinsics: .init(fx: 80, fy: 80, cx: 50, cy: 50, referenceSize: mask.size),
                depth: .init(size: mask.size, values: mask.values.map { $0 == 1 ? 1.2 : background },
                    confidence: Array(repeating: 2, count: 10000)), source: .synthetic, orientation: .up)
            let result = GarmentPlaneMeasurementEngine().measure(frame: frame, landmarks: landmarks,
                definitions: [.init(id: "top.totalLength", title: "총장", landmarkIDs: ["top_length_start", "hem_center"])])
            let length = try XCTUnwrap(result.values.first)
            XCTAssertEqual(length.status, .uncertain)
            XCTAssertEqual(try XCTUnwrap(length.meters), (0.895 - 0.27) * 100 / 80 * 1.2, accuracy: 0.00001)
        }
    }
}
