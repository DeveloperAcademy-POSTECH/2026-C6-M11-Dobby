//
//  HomeResumeCandidateTests.swift
//  DobbyPresentationTests
//
//  Created by mason on 10/27/26.
//

import Foundation
import XCTest
@testable import Dobby

@MainActor
final class HomeResumeCandidateTests: XCTestCase {
    func testLatestUsesDraftSaveTimeInsteadOfProductUpdateTime() throws {
        let older = try makeDraft(savedAt: 100)
        let newer = try makeDraft(savedAt: 200, step: .details)
        older.updatedAt = Date(timeIntervalSince1970: 300)
        newer.updatedAt = Date(timeIntervalSince1970: 50)

        let candidate = try XCTUnwrap(HomeResumeCandidate.latest(in: [newer, older]))
        XCTAssertEqual(candidate.garment.id, newer.id)
        XCTAssertEqual(candidate.draft.step, .details)
        XCTAssertEqual(candidate.draft.savedAt, Date(timeIntervalSince1970: 200))
    }

    func testCompletedLegacyAndUnreadableDraftsDoNotHideValidCandidate() throws {
        let valid = try makeDraft(savedAt: 100)
        let completed = try makeDraft(savedAt: 200)
        completed.informationCompletedAt = .now
        let legacy = Garment(category: "Jacket", group: .top)
        let unreadable = try makeDraft(savedAt: 300)
        unreadable.creationDraftData = Data("broken".utf8)
        let unsupported = try makeDraft(savedAt: 400)
        var draft = try XCTUnwrap(unsupported.creationDraft)
        draft.schemaVersion = 99
        unsupported.creationDraftData = try JSONEncoder().encode(draft)

        XCTAssertEqual(HomeResumeCandidate.latest(in: [completed, legacy, unreadable, unsupported, valid])?
            .garment.id, valid.id)
        XCTAssertNil(HomeResumeCandidate.latest(in: [completed, legacy, unreadable, unsupported]))
        XCTAssertNil(HomeResumeCandidate.latest(in: []))
    }

    func testMismatchedMeasurementOrProductCannotBecomeCandidate() throws {
        let mismatchedRecord = try makeDraft(savedAt: 100)
        mismatchedRecord.sourceMeasurementID = UUID()
        let mismatchedProduct = try makeDraft(savedAt: 200, step: .details)
        mismatchedProduct.id = UUID()
        XCTAssertNil(HomeResumeCandidate.latest(in: [mismatchedRecord, mismatchedProduct]))
    }

    func testEachStepRequiresItsPersistedState() throws {
        for step in ProductDraftStep.allCases {
            let garment = try makeDraft(savedAt: 100, step: step)
            XCTAssertEqual(HomeResumeCandidate.latest(in: [garment])?.draft.step, step)
            let draft = try XCTUnwrap(garment.creationDraft)
            garment.creationDraftData = try JSONEncoder().encode(ProductCreationDraft(
                step: step, measurementRecordID: draft.measurementRecordID,
                photoState: nil, measurementInputData: nil, savedAt: draft.savedAt))
            XCTAssertEqual(HomeResumeCandidate.latest(in: [garment]) != nil, step == .measurementResult)
        }
    }

    func testCompletionOrRemovalRevealsPreviousDraftWithoutChangingSavedData() throws {
        let older = try makeDraft(savedAt: 100)
        let newer = try makeDraft(savedAt: 200)
        let originalData = older.creationDraftData
        let originalUpdatedAt = older.updatedAt
        newer.informationCompletedAt = .now
        XCTAssertEqual(HomeResumeCandidate.latest(in: [older, newer])?.garment.id, older.id)
        XCTAssertEqual(HomeResumeCandidate.latest(in: [older])?.garment.id, older.id)
        XCTAssertEqual(older.creationDraftData, originalData)
        XCTAssertEqual(older.updatedAt, originalUpdatedAt)
    }

    func testEqualSaveTimesRemainStableRegardlessOfFetchOrder() throws {
        let first = try makeDraft(savedAt: 100)
        let second = try makeDraft(savedAt: 100)
        let expectedID = max(first.id.uuidString, second.id.uuidString)
        XCTAssertEqual(HomeResumeCandidate.latest(in: [first, second])?.garment.id.uuidString, expectedID)
        XCTAssertEqual(HomeResumeCandidate.latest(in: [second, first])?.garment.id.uuidString, expectedID)
    }

    /// 조회 조건만 검증하는 메타데이터. 실제 사진 저장·재개는 기존 persistence 테스트에서 검증한다.
    private func makeDraft(savedAt: TimeInterval, step: ProductDraftStep = .measurementResult) throws -> Garment {
        let garment = Garment(category: "Jacket", group: .top)
        let recordID = UUID()
        garment.sourceMeasurementID = recordID
        let sessionID = UUID()
        let measurement = CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garment.id,
            purpose: .measurement, capturedAt: .now, source: .mockPlaceholder)
        let input = ProductPhotoInput(sessionID: sessionID, garmentID: garment.id, measurement: measurement)
        let snapshot = try ProductPhotoDraftSnapshot(input: input, detailPhotos: [],
            selectedPhotoIDs: [measurement.id])
        garment.creationDraftData = try JSONEncoder().encode(ProductCreationDraft(
            step: step, measurementRecordID: recordID,
            photoState: step == .measurementResult ? nil : snapshot,
            measurementInputData: nil, savedAt: Date(timeIntervalSince1970: savedAt)))
        return garment
    }
}
