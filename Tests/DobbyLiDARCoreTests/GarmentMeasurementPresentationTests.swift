import Foundation
import XCTest
@testable import DobbyLiDARCore

final class GarmentMeasurementPresentationTests: XCTestCase {
    private func model(top: Bool) -> AutomaticMeasurement {
        let frame = SyntheticFixtures.scene().frame
        let coordinates: [(String, ImagePoint)] = top ? [
            ("neck_left", .init(x: 0.4, y: 0.2)), ("neck_right", .init(x: 0.6, y: 0.2)),
            ("shoulder_left", .init(x: 0.3, y: 0.3)), ("shoulder_right", .init(x: 0.7, y: 0.3)),
            ("armpit_left", .init(x: 0.35, y: 0.5)), ("armpit_right", .init(x: 0.65, y: 0.5)),
            ("sleeve_end_left", .init(x: 0.15, y: 0.6)), ("sleeve_end_right", .init(x: 0.85, y: 0.65)),
            ("hem_left", .init(x: 0.35, y: 0.85)), ("hem_center", .init(x: 0.5, y: 0.85)),
            ("hem_right", .init(x: 0.65, y: 0.85))
        ] : [
            ("waist_left", .init(x: 0.3, y: 0.15)), ("waist_right", .init(x: 0.7, y: 0.15)),
            ("waist_front_center", .init(x: 0.5, y: 0.18)),
            ("crotch", .init(x: 0.5, y: 0.45)), ("hem_left_outer", .init(x: 0.25, y: 0.85)),
            ("hem_left_inner", .init(x: 0.43, y: 0.85)), ("hem_right_outer", .init(x: 0.75, y: 0.8)),
            ("hem_right_inner", .init(x: 0.57, y: 0.8))
        ]
        var points = coordinates.map { GarmentLandmark(id: $0.0, point: $0.1, confidence: 1) }
        points.append(.init(id: top ? "neck_center" : "waist_center",
            point: .init(x: 0.5, y: top ? 0.2 : 0.15), confidence: 1,
            derivedFrom: top ? ["neck_left", "neck_right"] : ["waist_left", "waist_right"]))
        let edges = [["waist_left", "waist_right"], ["waist_front_center", "crotch"],
            ["waist_left", "hem_left_outer"], ["hem_left_outer", "hem_left_inner"],
            ["crotch", "hem_left_inner"], ["waist_right", "hem_right_outer"],
            ["hem_right_outer", "hem_right_inner"], ["crotch", "hem_right_inner"]]
        let definitions = top ? TopLandmarkSchema.legacyMeasurementDefinitions : edges.map {
            MeasurementDefinition(id: "bottom." + $0.sorted().joined(separator: "."),
                                  title: "원본 항목", landmarkIDs: $0)
        }
        let landmarks = GarmentLandmarkSet(sessionID: frame.sessionID, frameID: frame.frameID,
            origin: .synthetic, modelVersion: "presentation-test", points: points,
            mask: nil, garmentKind: top ? .top : .bottoms)
        let result = LiDARMeasurementEngine().measure(frame: frame, landmarks: landmarks, definitions: definitions)
        return .init(output: .init(runID: UUID(), snapshot: .init(frame: frame, imageJPEG: Data([1])),
            landmarks: landmarks, result: result, definitions: definitions, options: .init(),
            timings: .init(captureSeconds: 0, landmarksSeconds: 0, measurementSeconds: 0, totalSeconds: 0),
            startedAt: .now, finishedAt: .now))
    }

    func testTopShowsOneSleeveAndKeepsPhysicalProjectionContributors() throws {
        let model = model(top: true)
        XCTAssertEqual(model.visibleValues.map(\.id), ["top.totalLength", "top.shoulderWidth", "top.chestWidth",
            "top.sleeveLengthLeft"])
        XCTAssertEqual(model.visibleValues.map(\.title), ["총장", "어깨", "가슴", "소매"])
        let handles = Set(model.visibleEditableLandmarks.points.map(\.id))
        XCTAssertFalse(handles.contains("sleeve_end_right"))
        XCTAssertTrue(handles.contains("neck_center"))
        XCTAssertTrue(handles.isDisjoint(with: ["neck_left", "neck_right"]))
        XCTAssertTrue(handles.isSuperset(of: ["shoulder_right", "hem_center"]))
        XCTAssertFalse(handles.contains("hem_left"))
        XCTAssertFalse(handles.contains("hem_right"))
        XCTAssertEqual(model.visibleValues.first?.meters, model.result.values.first { $0.id == "top.totalLength" }?.meters)
        XCTAssertEqual(model.definitions.count, 6)
        XCTAssertEqual(model.landmarks.points.count, 12)
    }

    func testBottomShowsFourRowsAndArchivesAllBilateralEvidenceAfterPointCorrection() throws {
        var model = model(top: false)
        XCTAssertEqual(model.visibleValues.map(\.id), ["bottom.hem_left_outer.waist_left", "bottom.waist_left.waist_right",
            "bottom.crotch.waist_front_center", "bottom.hem_left_inner.hem_left_outer"])
        XCTAssertEqual(model.visibleValues.map(\.title), ["총장", "허리", "밑위", "밑단"])
        XCTAssertEqual(Set(model.visibleEditableLandmarks.points.map(\.id)),
                       ["waist_left", "waist_right", "waist_front_center", "crotch", "hem_left_outer", "hem_left_inner"])
        let originalRight = try XCTUnwrap(model.result.values.first { $0.id == "bottom.crotch.hem_right_inner" }?.meters)
        XCTAssertTrue(model.placePoint(originalPoint: .init(x: 0.42, y: 0.83), id: "hem_left_inner"))
        let result = LiDARMeasurementEngine().measure(frame: model.snapshot.frame,
            landmarks: model.calculationLandmarks, definitions: model.definitions)
        XCTAssertTrue(model.apply(result, for: model.calculationRevision))
        let record = try model.makeRecord()
        let decoded = try JSONDecoder().decode(SavedMeasurement.self, from: JSONEncoder().encode(record))
        let reopened = AutomaticMeasurement(record: decoded)
        XCTAssertEqual(reopened.result.values.count, 8)
        XCTAssertEqual(reopened.definitions.count, 8)
        XCTAssertEqual(reopened.landmarks.points.count, 9)
        XCTAssertEqual(reopened.visibleValues.count, 4)
        XCTAssertEqual(decoded.originalAutomaticResult?.values.count, 8)
        XCTAssertEqual(decoded.originalAutomaticLandmarks?.points.count, 9)
        XCTAssertEqual(reopened.result.values.first { $0.id == "bottom.crotch.hem_right_inner" }?.meters, originalRight)
        XCTAssertEqual(decoded.landmarks.points.first { $0.id == "hem_left_inner" }?.point, .init(x: 0.42, y: 0.83))
    }

    func testMissingLeftSleeveStaysVisibleForCorrectionWithoutSwitchingToRight() throws {
        var model = model(top: true)
        let leftID = "top.sleeveLengthLeft", rightID = "top.sleeveLengthRight"
        var result = model.result
        let left = try XCTUnwrap(result.values.firstIndex { $0.id == leftID })
        let right = try XCTUnwrap(result.values.firstIndex { $0.id == rightID })
        result.values[left].status = .unavailable
        result.values[left].meters = nil
        result.values[left].failure = .missingLandmark
        XCTAssertTrue(model.apply(result))
        XCTAssertEqual(model.visibleValues.filter { $0.status == .unavailable }.map(\.id), [leftID])
        XCTAssertFalse(model.visibleValues.contains { $0.id == rightID })
        XCTAssertTrue(model.visibleEditableLandmarks.points.contains { $0.id == "sleeve_end_left" })
        XCTAssertFalse(model.visibleEditableLandmarks.points.contains { $0.id == "sleeve_end_right" })
        result.values[right].status = .unavailable
        result.values[right].meters = nil
        XCTAssertTrue(model.apply(result))
        XCTAssertEqual(model.visibleValues.filter { $0.status == .unavailable }.map(\.id), [leftID])
        XCTAssertEqual(model.result.values.count, 6)
        XCTAssertEqual(model.visibleValues.count, 4)
    }

    func testFutureMeasurementItemsCanJoinOverlayWithoutDeletingHiddenRawItems() {
        let ids = ["bottom.waist_left.waist_right", "bottom.crotch.hem_left_inner",
                   "bottom.hipWidth", "bottom.thighWidth", "bottom.hem_right_outer.waist_right"]
        XCTAssertEqual(GarmentMeasurementPresentation.overlayMeasurements(ids, id: { $0 }),
                       ["bottom.waist_left.waist_right", "bottom.hipWidth", "bottom.thighWidth"])
        XCTAssertEqual(ids.count, 5)
    }

    func testProductColumnsMatchOverlayOrderTitlesAndValuesWithoutRightFallback() {
        struct Item { let id: String; let cm: Double }
        for top in [true, false] {
            let session = model(top: top)
            let columns = top ? GarmentMeasurementPresentation.topColumns : GarmentMeasurementPresentation.bottomColumns
            let rows = columns.reversed().map { column in
                Item(id: column.productKey, cm: session.result.values.first { $0.id == column.measurementID }!.meters! * 100)
            }
            let shown = GarmentMeasurementPresentation.productMeasurements(rows, isTop: top, key: { $0.id })
            XCTAssertEqual(shown.map(\.cm), session.visibleValues.map { $0.meters! * 100 })
            XCTAssertEqual(shown.map { GarmentMeasurementPresentation.productTitle(for: $0.id, fallback: "") },
                           session.visibleValues.map(\.title))
        }
        let rows = [Item(id: "sleeveLengthRight", cm: 62), Item(id: "hemWidth", cm: 44),
                    Item(id: "sleeveLengthLeft", cm: 0)]
        let shown = GarmentMeasurementPresentation.productMeasurements(rows, isTop: true, key: { $0.id })
        XCTAssertEqual(shown.map(\.id), ["sleeveLengthLeft"])
        XCTAssertEqual(shown.map(\.cm), [0])
    }

    func testOldAndNewRiseIDsShareVisibleColumnWithoutRewritingArchivedID() {
        for id in ["bottom.crotch.waist_center", "bottom.crotch.waist_front_center"] {
            let ids = ["bottom.hem_left_inner.hem_left_outer", id, "bottom.waist_left.waist_right"]
            XCTAssertEqual(GarmentMeasurementPresentation.overlayMeasurements(ids, id: { $0 }),
                           ["bottom.waist_left.waist_right", id, "bottom.hem_left_inner.hem_left_outer"])
            XCTAssertEqual(GarmentMeasurementPresentation.overlayTitle(for: id, fallback: "original"), "밑위")
            XCTAssertTrue(GarmentMeasurementPresentation.isVisibleMeasurementID(id, kind: .bottoms))
        }
    }

    func testProductSideSelectionPreservesOrderPrecisionAndUnknownFields() {
        struct Item { let id: String; let cm: Double }
        let rows = [Item(id: "custom", cm: 11.123456), .init(id: "inseamRight", cm: 72.125),
                    .init(id: "inseamLeft", cm: .nan), .init(id: "sleeveLengthRight", cm: 63.875),
                    .init(id: "sleeveLengthLeft", cm: 62.251234)]
        let shown = GarmentMeasurementPresentation.visibleMeasurements(rows, id: { $0.id },
            isUsable: { $0.cm.isFinite && $0.cm > 0 })
        XCTAssertEqual(shown.map(\.id), ["custom", "inseamRight", "sleeveLengthLeft"])
        XCTAssertEqual(shown.map(\.cm), [11.123456, 72.125, 62.251234])
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows[2].cm.isNaN)
        XCTAssertEqual(GarmentMeasurementPresentation.title(for: "custom", fallback: "기존 제목"), "기존 제목")
        XCTAssertEqual(GarmentMeasurementPresentation.shortTitle(for: "inseamRight", fallback: "우 인심"), "인심")
    }
}
