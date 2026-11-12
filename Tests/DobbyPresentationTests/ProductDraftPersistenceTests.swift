import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Dobby

/// Private synthetic captures exercise persistence, not model/sensor accuracy.
@MainActor
final class ProductDraftPersistenceTests: XCTestCase {
    func testDiskReopenPreservesStepEveryPhotoSelectionOrderAndPartialText() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        let camera = CameraPhotoStore(directory: directory.appending(path: "captures"))
        let first = try await camera.save(record.snapshot.imageJPEG, sessionID: record.snapshot.frame.sessionID,
            garmentID: record.id, capturedAt: .now)
        let second = try await camera.save(record.snapshot.imageJPEG, sessionID: record.snapshot.frame.sessionID,
            garmentID: record.id, capturedAt: .now)
        let inputData = Data("{\"partialMeasurement\":\"12.\"}".utf8)
        var measuredPhotoID: UUID!

        try autoreleasepool {
            let container = try makeContainer(at: directory.appending(path: "products.store"))
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory.appending(path: "photos"), allowsSynthetic: true)
            let input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID,
                photosDirectory: directory.appending(path: "photos"))
            measuredPhotoID = input.measurement.id
            garment.name = "아직 작성 중인 제품"
            garment.detail = "마저 적을 설명"
            let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
                initialDetailPhotos: [first, second], initialSelectedPhotoIDs: [second.id, input.measurement.id, first.id])
            model.acknowledgeCaptureGuide()
            try ProductDraftStore.save(garment: garment, step: .photoSelection,
                measurementRecordID: record.id, photoModel: model, measurementInputData: inputData,
                aiReviewNotes: ["라벨을 실물로 확인해 주세요."], usesProductAutofill: false, in: context)
            // A save from another entry point must not erase the existing AI guidance.
            try ProductDraftStore.save(garment: garment, step: .photoSelection,
                measurementRecordID: record.id, photoModel: model, measurementInputData: inputData, in: context)
        }

        try autoreleasepool {
            let container = try makeContainer(at: directory.appending(path: "products.store"))
            let garment = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Garment>()).first)
            let draft = try XCTUnwrap(garment.creationDraft)
            XCTAssertTrue(garment.isCreationDraft)
            XCTAssertEqual(draft.step, .photoSelection)
            XCTAssertEqual(draft.step.title, "상세 촬영 단계", "기존 저장 값은 유지하고 이어하기 안내만 새 경로에 맞춘다")
            XCTAssertEqual(draft.measurementRecordID, record.id)
            XCTAssertEqual(draft.measurementInputData, inputData)
            XCTAssertEqual(draft.aiReviewNotes, ["라벨을 실물로 확인해 주세요."])
            XCTAssertEqual(draft.usesProductAutofill, false)
            XCTAssertEqual(garment.name, "아직 작성 중인 제품")
            XCTAssertEqual(garment.detail, "마저 적을 설명")
            let input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID,
                photosDirectory: directory.appending(path: "photos"))
            let state = try XCTUnwrap(draft.photoState)
            let restored = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
                initialDetailPhotos: state.restoredDetailPhotos(for: input),
                initialSelectedPhotoIDs: state.selectedPhotoIDs)
            XCTAssertEqual(state.hasAcknowledgedCaptureGuide, true)
            if state.hasAcknowledgedCaptureGuide == true { restored.acknowledgeCaptureGuide() }
            XCTAssertTrue(restored.hasAcknowledgedCaptureGuide)
            XCTAssertEqual(restored.detailPhotos, [first, second])
            XCTAssertEqual(restored.selectedPhotoIDs, [second.id, measuredPhotoID!, first.id])
            XCTAssertEqual(restored.output?.representativePhotoID, second.id)
            XCTAssertEqual(restored.output?.selectedPhotos.map(\.id), restored.selectedPhotoIDs)
            XCTAssertEqual(restored.allPhotosOutput?.selectedPhotos.map(\.id),
                [measuredPhotoID!, first.id, second.id], "이전 선택 순서와 관계없이 보존된 전체 촬영 사진을 전달한다")
            var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            legacyJSON.removeValue(forKey: "hasAcknowledgedCaptureGuide")
            let legacy = try JSONDecoder().decode(ProductPhotoDraftSnapshot.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON))
            XCTAssertNil(legacy.hasAcknowledgedCaptureGuide)
            let legacyModel = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
                initialDetailPhotos: legacy.restoredDetailPhotos(for: input), initialSelectedPhotoIDs: legacy.selectedPhotoIDs)
            if legacy.hasAcknowledgedCaptureGuide == true { legacyModel.acknowledgeCaptureGuide() }
            XCTAssertFalse(legacyModel.hasAcknowledgedCaptureGuide)
        }
    }

    func testZeroSelectionIsSavedWithoutPromotingAnUnfinishedProduct() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture())
        XCTAssertNil(model.output)
        try ProductDraftStore.save(garment: fixture.garment, step: .photoSelection,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil,
            in: fixture.context)
        let draft = try XCTUnwrap(fixture.garment.creationDraft)
        XCTAssertTrue(draft.photoState?.selectedPhotoIDs.isEmpty == true)
        XCTAssertNil(fixture.garment.informationCompletedAt)
        XCTAssertTrue(fixture.garment.isCreationDraft)
    }

    func testDiskReopenPreservesOverflowInformationOrderExclusionsAndPartialInput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        let camera = CameraPhotoStore(directory: directory.appending(path: "captures"))
        var details: [CapturedAsset] = []
        for _ in 0..<12 {
            details.append(try await camera.save(record.snapshot.imageJPEG,
                sessionID: record.snapshot.frame.sessionID, garmentID: record.id, capturedAt: .now))
        }
        let excludedID = details[3].id
        let inputData = Data("{\"partialMeasurement\":\"12.\"}".utf8)
        let productPhotosDirectory = directory.appending(path: "photos")
        let databaseURL = directory.appending(path: "products.store")
        var expectedIDs: [UUID] = []
        var measurementID: UUID?

        do {
            let container = try makeContainer(at: databaseURL)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: productPhotosDirectory, allowsSynthetic: true)
            let input = try ProductPhotoHandoff.makeInput(for: garment,
                sessionID: record.snapshot.frame.sessionID, photosDirectory: productPhotosDirectory)
            measurementID = input.measurement.id
            let model = try ProductPhotoModel(input: input, captureProvider: NoCapture(), initialDetailPhotos: details)
            let output = try XCTUnwrap(model.allPhotosOutput)
            try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: input,
                photosDirectory: productPhotosDirectory, includesAllCapturedPhotos: true)
            XCTAssertTrue(try GarmentStore.removeProductPhoto(id: excludedID, from: garment, in: context,
                persist: { _ in }))
            expectedIDs = [details[11].id, input.measurement.id]
                + details.dropLast().reversed().filter { $0.id != excludedID }.map(\.id)
            XCTAssertTrue(GarmentStore.reorderProductPhotos(ids: expectedIDs, in: garment))
            XCTAssertTrue(model.synchronizeSelectedProductPhotos(garment.productPhotos.map(\.id)))
            garment.name = "사진을 더 정리할 제품"
            garment.detail = "작성 중인 설명"
            try ProductDraftStore.save(garment: garment, step: .information,
                measurementRecordID: record.id, photoModel: model, measurementInputData: inputData, in: context)
            XCTAssertEqual(garment.productPhotos.count, 12)
            XCTAssertNil(garment.informationCompletedAt)
        }

        try autoreleasepool {
            let container = try makeContainer(at: databaseURL)
            let context = ModelContext(container)
            let garment = try XCTUnwrap(context.fetch(FetchDescriptor<Garment>()).first)
            let draft = try XCTUnwrap(garment.creationDraft)
            let state = try XCTUnwrap(draft.photoState)
            let input = try ProductPhotoHandoff.makeInput(for: garment,
                sessionID: record.snapshot.frame.sessionID, photosDirectory: productPhotosDirectory)
            let restored = try ProductPhotoModel(input: input, captureProvider: NoCapture(),
                initialDetailPhotos: state.restoredDetailPhotos(for: input),
                initialSelectedPhotoIDs: state.selectedPhotoIDs)
            XCTAssertTrue(garment.isCreationDraft)
            XCTAssertEqual(draft.step, .information)
            XCTAssertEqual(draft.measurementInputData, inputData)
            XCTAssertEqual(garment.name, "사진을 더 정리할 제품")
            XCTAssertEqual(garment.detail, "작성 중인 설명")
            XCTAssertNil(garment.price)
            XCTAssertNil(garment.informationCompletedAt)
            XCTAssertEqual(garment.productPhotos.map(\.id), expectedIDs)
            XCTAssertEqual(garment.thumbnail?.id, expectedIDs.first)
            XCTAssertEqual(garment.measurementPhoto?.id, measurementID)
            XCTAssertEqual(garment.photos.first { $0.id == excludedID }?.isSelectedForProduct, false)
            XCTAssertEqual(garment.photos.count, 13)
            XCTAssertEqual(restored.detailPhotos, details)
            XCTAssertEqual(restored.selectedPhotoIDs, expectedIDs)
            XCTAssertEqual(restored.informationOutput?.selectedPhotos.map(\.id), expectedIDs)
            XCTAssertEqual(restored.informationOutput?.representativePhotoID, expectedIDs.first)
            XCTAssertNil(restored.output, "The legacy selection output still enforces its ten-photo boundary")
            XCTAssertEqual(restored.allPhotosOutput?.selectedPhotos.count, 13,
                "Excluding a product photo must retain its captured original")
            for photo in garment.photos {
                XCTAssertTrue(FileManager.default.fileExists(atPath: productPhotosDirectory.appending(path: photo.fileName).path))
            }
        }
        for detail in details {
            guard case let .localFile(url, _) = detail.source else { return XCTFail("Expected camera original") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSavedDraftRestoresSelectionLimitAndUnselectedOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CameraPhotoStore(directory: fixture.directory.appending(path: "captures"))
        var details: [CapturedAsset] = []
        for _ in 0..<11 {
            details.append(try await store.save(fixture.record.snapshot.imageJPEG,
                sessionID: fixture.input.sessionID, garmentID: fixture.garment.id, capturedAt: .now))
        }
        let selected = [details[9].id, fixture.input.measurement.id] + details.prefix(8).map(\.id)
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(),
            initialDetailPhotos: details, initialSelectedPhotoIDs: selected)
        try ProductDraftStore.save(garment: fixture.garment, step: .photoSelection,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil,
            in: fixture.context)

        let reader = ModelContext(fixture.container)
        let saved = try XCTUnwrap(reader.fetch(FetchDescriptor<Garment>()).first)
        let state = try XCTUnwrap(saved.creationDraft?.photoState)
        let restored = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(),
            initialDetailPhotos: state.restoredDetailPhotos(for: fixture.input),
            initialSelectedPhotoIDs: state.selectedPhotoIDs)
        XCTAssertEqual(restored.detailPhotos, details)
        XCTAssertEqual(restored.selectedPhotoIDs, selected)
        XCTAssertEqual(restored.output?.selectedPhotos.map(\.id), selected)
        XCTAssertEqual(restored.output?.representativePhotoID, selected.first)
        XCTAssertEqual(restored.toggleSelection(details[10].id), .limitReached)
        XCTAssertEqual(restored.selectedPhotoIDs, selected)
        XCTAssertEqual(restored.toggleSelection(selected[0]), .updated)
        XCTAssertEqual(restored.toggleSelection(details[10].id), .updated)
        XCTAssertEqual(restored.selectedPhotoIDs, Array(selected.dropFirst()) + [details[10].id])
        XCTAssertEqual(restored.output?.representativePhotoID, selected[1])
        XCTAssertEqual(restored.detailPhotos, details, "The selection limit must retain unselected originals")
        for detail in details {
            guard case let .localFile(url, _) = detail.source else { return XCTFail("Expected owned original") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testFailedSaveKeepsPreviousResumePointAndCurrentUnsavedTextAndFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CameraPhotoStore(directory: fixture.directory.appending(path: "captures"))
        let asset = try await store.save(fixture.record.snapshot.imageJPEG,
            sessionID: fixture.input.sessionID, garmentID: fixture.garment.id, capturedAt: .now)
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(),
            initialDetailPhotos: [asset], initialSelectedPhotoIDs: [fixture.input.measurement.id])
        try ProductDraftStore.save(garment: fixture.garment, step: .details,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil, in: fixture.context)
        let priorData = fixture.garment.creationDraftData
        let priorUpdatedAt = fixture.garment.updatedAt
        fixture.garment.name = "저장 실패해도 유지할 입력"
        model.toggleSelection(fixture.input.measurement.id)
        XCTAssertThrowsError(try ProductDraftStore.save(garment: fixture.garment, step: .information,
            measurementRecordID: fixture.record.id, photoModel: model,
            measurementInputData: Data("잘못된 숫자도 복원".utf8), in: fixture.context,
            persist: { _ in throw TestFailure.save }))
        XCTAssertEqual(fixture.garment.creationDraftData, priorData)
        XCTAssertEqual(fixture.garment.updatedAt, priorUpdatedAt)
        XCTAssertEqual(fixture.garment.name, "저장 실패해도 유지할 입력")
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
        XCTAssertEqual(model.detailPhotos, [asset])
        guard case let .localFile(url, _) = asset.source else { return XCTFail("Expected owned capture") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let durable = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Garment>()).first)
        XCTAssertEqual(durable.creationDraft?.step, .details)
        XCTAssertNotEqual(durable.name, fixture.garment.name)
    }

    func testUnreadableOrMismatchedCapturedFilesDoNotBecomeASavedDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CameraPhotoStore(directory: fixture.directory.appending(path: "captures"))
        let asset = try await store.save(fixture.record.snapshot.imageJPEG,
            sessionID: fixture.input.sessionID, garmentID: fixture.garment.id, capturedAt: .now)
        XCTAssertThrowsError(try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(),
            initialDetailPhotos: [asset, asset]))
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(), initialDetailPhotos: [asset])
        guard case let .localFile(url, _) = asset.source else { return XCTFail("Expected captured file") }
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try ProductDraftStore.save(garment: fixture.garment, step: .details,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil, in: fixture.context))
        XCTAssertNil(fixture.garment.creationDraftData)
    }

    func testDeletingSavedCaptureThenFailingSaveKeepsPreviousDraftReadable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CameraPhotoStore(directory: fixture.directory.appending(path: "captures"))
        let asset = try await store.save(fixture.record.snapshot.imageJPEG,
            sessionID: fixture.input.sessionID, garmentID: fixture.garment.id, capturedAt: .now)
        guard case let .localFile(url, _) = asset.source else { return XCTFail("Expected owned original") }
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: StoreProvider(store: store),
            initialDetailPhotos: [asset], initialSelectedPhotoIDs: [asset.id])
        try ProductDraftStore.save(garment: fixture.garment, step: .details,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil, in: fixture.context)
        try await model.deleteDetail(asset.id)
        XCTAssertTrue(model.detailPhotos.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "The last saved draft still owns this original")
        XCTAssertThrowsError(try ProductDraftStore.save(garment: fixture.garment, step: .photoSelection,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil,
            in: fixture.context, persist: { _ in throw TestFailure.save }))
        let saved = try XCTUnwrap(ModelContext(fixture.container).fetch(FetchDescriptor<Garment>()).first)
        let savedState = try XCTUnwrap(saved.creationDraft?.photoState)
        XCTAssertEqual(try savedState.restoredDetailPhotos(for: fixture.input), [asset])
        XCTAssertEqual(savedState.selectedPhotoIDs, [asset.id])
        try ProductDraftStore.save(garment: fixture.garment, step: .photoSelection,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil, in: fixture.context)
        try await model.discardUncommittedDetails()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDraftDeletionRemovesOnlyItsStoreOwnedCameraOriginals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = CameraPhotoStore()
        let asset = try await store.save(fixture.record.snapshot.imageJPEG,
            sessionID: fixture.input.sessionID, garmentID: fixture.garment.id, capturedAt: .now)
        guard case let .localFile(url, _) = asset.source else { return XCTFail("Expected camera original") }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(), initialDetailPhotos: [asset])
        try ProductDraftStore.save(garment: fixture.garment, step: .details,
            measurementRecordID: fixture.record.id, photoModel: model, measurementInputData: nil, in: fixture.context)
        let originalDraft = try XCTUnwrap(fixture.garment.creationDraft)
        XCTAssertEqual(ProductDraftStore.retainedCameraPhotoURLs(in: originalDraft, garmentID: fixture.garment.id), [url])
        let other = fixture.directory.appending(path: "unrelated.jpg")
        try fixture.record.snapshot.imageJPEG.write(to: other)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(originalDraft)) as? [String: Any])
        var state = try XCTUnwrap(json["photoState"] as? [String: Any])
        var photos = try XCTUnwrap(state["detailPhotos"] as? [[String: Any]])
        photos[0]["url"] = other.absoluteString
        state["detailPhotos"] = photos
        json["photoState"] = state
        let tampered = try JSONDecoder().decode(ProductCreationDraft.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(ProductDraftStore.retainedCameraPhotoURLs(in: tampered, garmentID: fixture.garment.id).isEmpty)
        XCTAssertTrue(try GarmentStore.deleteSavedGarment(id: fixture.garment.id, in: fixture.container))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testMeasurementRefreshKeepsProductPhotoAndFieldIDsWhileUpdatingEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let garmentID = fixture.garment.id
        let photoID = fixture.garment.measurementPhoto?.id
        let fileName = fixture.garment.measurementPhoto?.fileName
        let measurementIDs = Dictionary(uniqueKeysWithValues: fixture.garment.measurements.map { ($0.key, $0.id) })
        fixture.garment.name = "정보와 사진은 유지"
        fixture.garment.brand = "테스트 브랜드"
        var corrected = fixture.record
        corrected.id = UUID()
        corrected.originalAutomaticLandmarks = corrected.landmarks
        corrected.originalAutomaticResult = corrected.result
        let landmarkIndex = try XCTUnwrap(corrected.landmarks.points.firstIndex { $0.id == "armpit_left" })
        corrected.landmarks.points[landmarkIndex].point.x += 0.03
        corrected.landmarks.points[landmarkIndex].origin = .manual
        corrected.landmarks.points[landmarkIndex].confidence = nil
        let chestIndex = try XCTUnwrap(corrected.result.values.firstIndex { $0.id == "top.chestWidth" })
        let previousChest = try XCTUnwrap(corrected.result.values[chestIndex].meters)
        corrected.result.values[chestIndex].meters = previousChest + 0.03
        try GarmentStore.refreshMeasurement(corrected, for: fixture.garment, in: fixture.context, allowsSynthetic: true)
        let photoModel = try ProductPhotoModel(input: fixture.input, captureProvider: NoCapture(),
            measurementRecord: fixture.record)
        try photoModel.updateMeasurementRecord(corrected)
        XCTAssertEqual(photoModel.measurementRecord?.id, corrected.id)
        XCTAssertEqual(photoModel.measurementRecord?.result.values[chestIndex].meters, previousChest + 0.03)
        var foreignFrame = corrected
        foreignFrame.snapshot.frame.frameID = UUID()
        XCTAssertThrowsError(try photoModel.updateMeasurementRecord(foreignFrame))
        XCTAssertEqual(photoModel.measurementRecord?.id, corrected.id)
        XCTAssertEqual(fixture.garment.id, garmentID)
        XCTAssertEqual(fixture.garment.measurementPhoto?.id, photoID)
        XCTAssertEqual(fixture.garment.measurementPhoto?.fileName, fileName)
        XCTAssertEqual(fixture.garment.sourceMeasurementID, corrected.id)
        XCTAssertEqual(fixture.garment.measurementPhoto?.measurementRecordID, corrected.id)
        XCTAssertEqual(fixture.garment.name, "정보와 사진은 유지")
        XCTAssertEqual(fixture.garment.brand, "테스트 브랜드")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fixture.garment.measurements.map { ($0.key, $0.id) }), measurementIDs)
        XCTAssertEqual(try XCTUnwrap(fixture.garment.measurement("chestWidth")?.valueCm),
            StoredMeasurementValue.centimeters((previousChest + 0.03) * 100), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fixture.garment.measurement("chestWidth")?.autoValueCm), previousChest * 100, accuracy: 1e-9)
        XCTAssertTrue(fixture.garment.measurementPhoto?.landmark("armpit_left")?.isMoved == true)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<Garment>()), 1)
        let sleeveIndex = try XCTUnwrap(corrected.result.values.firstIndex { $0.id == "top.sleeveLengthRight" })
        corrected.id = UUID()
        corrected.result.values[sleeveIndex].meters = nil
        corrected.result.values[sleeveIndex].status = .unavailable
        try GarmentStore.refreshMeasurement(corrected, for: fixture.garment, in: fixture.context, allowsSynthetic: true)
        XCTAssertEqual(fixture.garment.measurement("sleeveLengthRight")?.valueCm, 0)
        XCTAssertEqual(fixture.garment.measurement("sleeveLengthRight")?.sourceStatusRaw, "unavailable")
        XCTAssertEqual(fixture.garment.measurement("sleeveLengthRight")?.id, measurementIDs["sleeveLengthRight"])
        let unrelated = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
        XCTAssertThrowsError(try GarmentStore.refreshMeasurement(unrelated, for: fixture.garment,
            in: fixture.context, allowsSynthetic: true))
        XCTAssertEqual(fixture.garment.sourceMeasurementID, corrected.id)
    }

    func testLegacyAndCompletedProductsAreNotResumableDrafts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        XCTAssertFalse(fixture.garment.isCreationDraft)
        try ProductDraftStore.save(garment: fixture.garment, step: .measurementResult,
            measurementRecordID: fixture.record.id, photoModel: nil, measurementInputData: nil, in: fixture.context)
        XCTAssertTrue(fixture.garment.isCreationDraft)
        fixture.garment.informationCompletedAt = .now
        XCTAssertFalse(fixture.garment.isCreationDraft)
        XCTAssertThrowsError(try ProductDraftStore.save(garment: fixture.garment, step: .measurementResult,
            measurementRecordID: fixture.record.id, photoModel: nil, measurementInputData: nil, in: fixture.context))
    }

    func testAllUnavailableResultCanOnlyBePersistedThroughExplicitDraftException() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var unavailable = fixture.record
        unavailable.id = UUID()
        for index in unavailable.result.values.indices {
            unavailable.result.values[index].meters = nil
            unavailable.result.values[index].status = .unavailable
        }
        let photoDirectory = fixture.directory.appending(path: "photos")
        XCTAssertThrowsError(try GarmentStore.importMeasurement(unavailable, in: fixture.context,
            photosDirectory: photoDirectory, allowsSynthetic: true)) { error in
            guard case GarmentStore.MeasurementImportError.noAvailableMeasurements = error else {
                return XCTFail("Normal confirmation must reject an entirely unavailable result")
            }
        }
        let draft = try GarmentStore.importMeasurement(unavailable, in: fixture.context,
            photosDirectory: photoDirectory, allowsSynthetic: true, allowsUnavailableDraft: true)
        try ProductDraftStore.save(garment: draft, step: .measurementResult,
            measurementRecordID: unavailable.id, photoModel: nil, measurementInputData: nil, in: fixture.context)
        XCTAssertTrue(draft.isCreationDraft)
        XCTAssertEqual(draft.creationDraft?.step, .measurementResult)
        XCTAssertEqual(draft.sourceMeasurementID, unavailable.id)
        XCTAssertEqual(draft.measurementPhoto?.measurementFrameID, unavailable.snapshot.frame.frameID)
        XCTAssertEqual(draft.measurementPhoto?.landmarks.count, unavailable.landmarks.points.count)
        XCTAssertTrue(draft.measurements.allSatisfy { $0.valueCm == 0 && $0.sourceStatusRaw == "unavailable" })
        XCTAssertThrowsError(try GarmentStore.refreshMeasurement(unavailable, for: fixture.garment,
            in: fixture.context, allowsSynthetic: true)) { error in
            guard case GarmentStore.MeasurementImportError.noAvailableMeasurements = error else {
                return XCTFail("Normal refresh must preserve the usable-result requirement")
            }
        }
        XCTAssertEqual(fixture.garment.sourceMeasurementID, fixture.record.id)
        let preservedIDs = Set(fixture.garment.measurements.map(\.id))
        try GarmentStore.refreshMeasurement(unavailable, for: fixture.garment,
            in: fixture.context, allowsSynthetic: true, allowsUnavailableDraft: true)
        XCTAssertEqual(fixture.garment.sourceMeasurementID, unavailable.id)
        XCTAssertEqual(fixture.garment.measurements.count, preservedIDs.count)
        XCTAssertEqual(Set(fixture.garment.measurements.map(\.id)), preservedIDs)
        XCTAssertTrue(fixture.garment.measurements.allSatisfy { $0.valueCm == 0 && $0.sourceStatusRaw == "unavailable" })
    }

    private final class NoCapture: CaptureProviding {
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset { throw CameraFailure.captureFailed }
    }

    private final class StoreProvider: CaptureProviding {
        let store: CameraPhotoStore
        init(store: CameraPhotoStore) { self.store = store }
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset { throw CameraFailure.captureFailed }
        func discardUncommitted(_ asset: CapturedAsset) async throws { try await store.discardUncommitted(asset) }
    }

    private enum TestFailure: Error { case save }

    private func makeDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "dobby-creation-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = ProductAppStorage.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        ])
    }

    private struct Fixture {
        let directory: URL
        let container: ModelContainer
        let context: ModelContext
        let record: SavedMeasurement
        let garment: Garment
        let input: ProductPhotoInput

        init() throws {
            directory = URL.temporaryDirectory.appending(path: "dobby-creation-draft-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let schema = ProductAppStorage.schema
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
            context = ModelContext(container)
            context.autosaveEnabled = false
            record = try GarmentCapturePreview.measurement(kind: .top).makeRecord()
            garment = try GarmentStore.importMeasurement(record, in: context,
                photosDirectory: directory.appending(path: "photos"), allowsSynthetic: true)
            input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID,
                photosDirectory: directory.appending(path: "photos"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
