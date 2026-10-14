import XCTest
@testable import DobbyLiDARCore

final class GarmentPoseOrientationRecoveryTests: XCTestCase {
    func testPrimarySuccessDoesNotRotateOrInspectPartialCandidates() throws {
        var attempts: [ImageOrientation] = []
        var partialCalls = 0
        let result = try GarmentPoseOrientationRecovery.perform(orientation: .right, allowsHalfTurn: true,
            strictAttempt: { attempts.append($0); return "primary" },
            partialResult: { partialCalls += 1; return "partial" })
        XCTAssertEqual(result, "primary")
        XCTAssertEqual(attempts, [.right])
        XCTAssertEqual(partialCalls, 0)
    }

    func testViablePrimarySubjectKeepsItsPointsBeforeTryingHalfTurn() throws {
        let raw = [GarmentLandmark(id: "hem_center", point: .init(x: 0.42, y: 0.81), confidence: 0.91)]
        var calls: [String] = []
        let result = try GarmentPoseOrientationRecovery.perform(orientation: .right, allowsHalfTurn: true,
            strictAttempt: { direction -> [GarmentLandmark] in
                calls.append("strict.\(direction.rawValue)")
                throw GarmentMaskAssociationError.unmatchedGarment
            }, subjectAttempt: { direction in
                calls.append("subject.\(direction.rawValue)")
                return raw
            }, partialResult: { calls.append("legacyPartial"); return [] })
        XCTAssertEqual(calls, ["strict.right", "subject.right"])
        XCTAssertEqual(result.map(\.point), raw.map(\.point))
        XCTAssertEqual(result.map(\.confidence), raw.map(\.confidence))
        XCTAssertEqual(result.map(\.isVisible), raw.map(\.isVisible))
    }

    func testExactOrientationCanUseSameOrientationSubjectWithoutRotation() throws {
        var calls: [String] = []
        let result = try GarmentPoseOrientationRecovery.perform(orientation: .left, allowsHalfTurn: false,
            strictAttempt: { direction -> ImageOrientation in
                calls.append("strict.\(direction.rawValue)")
                throw GarmentMaskAssociationError.unmatchedGarment
            }, subjectAttempt: { direction in calls.append("subject.\(direction.rawValue)"); return direction })
        XCTAssertEqual(result, .left)
        XCTAssertEqual(calls, ["strict.left", "subject.left"])
    }

    func testUnusablePrimarySubjectAllowsOnlyOneHalfTurn() throws {
        var calls: [String] = []
        let result = try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
            strictAttempt: { direction -> String in
                calls.append("strict.\(direction.rawValue)")
                throw GarmentMaskAssociationError.unmatchedGarment
            }, subjectAttempt: { direction in
                calls.append("subject.\(direction.rawValue)")
                return direction == .down ? "rotatedSubject" : nil
            })
        XCTAssertEqual(result, "rotatedSubject")
        XCTAssertEqual(calls, ["strict.up", "subject.up", "strict.down", "subject.down"])
    }

    func testHardFailureAndCancelledSubjectCannotBeBypassedByRotation() {
        var subjectCalls = 0
        XCTAssertThrowsError(try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
            strictAttempt: { _ -> String in throw GarmentMaskAssociationError.multipleForegrounds },
            subjectAttempt: { _ in subjectCalls += 1; return "unsafe" })) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .multipleForegrounds)
        }
        XCTAssertEqual(subjectCalls, 0)
        var strictCalls = 0
        XCTAssertThrowsError(try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
            strictAttempt: { _ -> String in strictCalls += 1; throw GarmentMaskAssociationError.unmatchedGarment },
            subjectAttempt: { _ -> String? in throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(strictCalls, 1)
    }

    func testRecoverableFailureTriesExactlyOneHalfTurnBeforePartialCandidates() throws {
        for error in [BottomLandmarkError.noDetection as Error, GarmentMaskAssociationError.unmatchedGarment] {
            var attempts: [ImageOrientation] = []
            var partialCalls = 0
            let result = try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
                strictAttempt: { direction in
                    attempts.append(direction)
                    if direction == .up { throw error }
                    return "strict rotated"
                }, partialResult: { partialCalls += 1; return "partial" })
            XCTAssertEqual(result, "strict rotated")
            XCTAssertEqual(attempts, [.up, .down])
            XCTAssertEqual(partialCalls, 0)
        }
    }

    func testBothStrictFailuresInspectPartialOnlyAfterTheTwoAttempts() throws {
        var calls: [String] = []
        let result = try GarmentPoseOrientationRecovery.perform(orientation: .right, allowsHalfTurn: true,
            strictAttempt: { direction -> String in
                calls.append(direction.rawValue)
                throw GarmentMaskAssociationError.unmatchedGarment
            },
            partialResult: { calls.append("partial"); return "body" })
        XCTAssertEqual(result, "body")
        XCTAssertEqual(calls, ["right", "left", "partial"])
    }

    func testFailedHalfTurnPreservesThePrimaryFailure() {
        var attempts = 0
        XCTAssertThrowsError(try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
            strictAttempt: { _ -> String in
                attempts += 1
                if attempts == 1 { throw GarmentMaskAssociationError.unmatchedGarment }
                throw BottomLandmarkError.noDetection
            })) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .unmatchedGarment)
        }
        XCTAssertEqual(attempts, 2)
    }

    func testBottomsAndHardFailuresDoNotTryRotationOrPartialSupport() {
        for configuration in [(false, BottomLandmarkError.noDetection as Error),
                              (true, BottomLandmarkError.multipleGarments as Error),
                              (true, GarmentMaskAssociationError.multipleForegrounds as Error),
                              (true, GarmentMaskAssociationError.invalidMask as Error),
                              (true, CancellationError() as Error)] {
            var attempts = 0
            var partialCalls = 0
            XCTAssertThrowsError(try GarmentPoseOrientationRecovery.perform(orientation: .up,
                allowsHalfTurn: configuration.0,
                strictAttempt: { _ -> String in attempts += 1; throw configuration.1 },
                partialResult: { partialCalls += 1; return "unsafe" }))
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(partialCalls, 0)
        }
    }

    func testMultipleForegroundsDuringRecoveryCannotBeBypassedByPartialSupport() {
        var attempts = 0
        var partialCalls = 0
        XCTAssertThrowsError(try GarmentPoseOrientationRecovery.perform(orientation: .up, allowsHalfTurn: true,
            strictAttempt: { _ -> String in
                attempts += 1
                if attempts == 1 { throw GarmentMaskAssociationError.unmatchedGarment }
                throw GarmentMaskAssociationError.multipleForegrounds
            }, partialResult: { partialCalls += 1; return "unsafe" })) {
            XCTAssertEqual($0 as? GarmentMaskAssociationError, .multipleForegrounds)
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(partialCalls, 0)
    }

    func testHalfTurnCompositionPreservesRawCoordinateMappingForEveryCameraOrientation() throws {
        let size = PixelSize(width: 640, height: 480)
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let turned = GarmentPoseOrientationRecovery.halfTurn(of: orientation)
            XCTAssertEqual(GarmentPoseOrientationRecovery.halfTurn(of: turned), orientation)
            let geometry = try BottomLetterboxGeometry(originalSize: size, orientation: turned)
            let raw = ImagePoint(x: 0.3, y: 0.7)
            let display = ImageCoordinateTransform.originalToDisplay(raw, orientation: turned)
            let restored = try XCTUnwrap(geometry.originalPoint(
                modelX: display.x * Double(geometry.resizedSize.width) + Double(geometry.padLeft),
                modelY: display.y * Double(geometry.resizedSize.height) + Double(geometry.padTop)))
            XCTAssertEqual(restored.x, raw.x, accuracy: 0.000_001)
            XCTAssertEqual(restored.y, raw.y, accuracy: 0.000_001)
        }
    }
}
