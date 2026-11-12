// Created by mason on 10/25/26.
import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoSelectionLimitTests {
    @Test func zeroOneAndTenSelectionsProduceOnlyValidOutput() async throws {
        let model = try await makeModel()
        let photos = model.photos
        #expect(model.output == nil)
        #expect(model.toggleSelection(photos[0].id) == .updated)
        #expect(model.output?.selectedPhotos == [photos[0]])
        for photo in photos[1..<10] { #expect(model.toggleSelection(photo.id) == .updated) }
        let output = try #require(model.output)
        #expect(output.selectedPhotos == Array(photos.prefix(10)))
        #expect(output.representativePhotoID == photos[0].id)
        #expect(output.sessionID == model.input.sessionID)
        #expect(output.garmentID == model.input.garmentID)
        for _ in 0..<3 { #expect(model.toggleSelection(photos[10].id) == .limitReached) }
        #expect(model.toggleSelection(UUID()) == .ignored)
        #expect(model.output?.selectedPhotos == output.selectedPhotos)
        #expect(model.photos == photos, "선택 제한으로 촬영된 사진을 잃지 않는다")
        #expect(model.detailPhotos.count == 11, "10장은 촬영 개수 제한이 아니다")
    }

    @Test func deselectionAtLimitRenumbersAndReselectionAppends() async throws {
        let model = try await makeModel()
        let photos = model.photos
        // 촬영 순서와 다른 순서로 선택해 출력이 선택 순서를 따르는지 확인한다.
        let selected = Array(photos[1...10].reversed())
        for photo in selected { model.toggleSelection(photo.id) }
        #expect(model.toggleSelection(selected[0].id) == .updated)
        #expect(model.output?.representativePhotoID == selected[1].id)
        #expect(model.toggleSelection(selected[0].id) == .updated)
        let expected = Array(selected.dropFirst()) + [selected[0]]
        #expect(model.selectedPhotoIDs == expected.map(\.id))
        #expect(model.output?.selectedPhotos == expected)
        #expect(model.photos == photos)
        for photo in expected { #expect(model.toggleSelection(photo.id) == .updated) }
        #expect(model.selectedPhotoIDs.isEmpty)
        #expect(model.output == nil)
        #expect(model.photos == photos)
        #expect(model.toggleSelection(photos[0].id) == .updated)
        #expect(model.output?.representativePhotoID == photos[0].id)
    }

    @Test func informationSelectionKeepsOverflowOrderWhileLegacyOutputRemainsLimited() async throws {
        let model = try await makeModel()
        let ordered = Array(model.selectablePhotos.reversed())
        let ids = ordered.map(\.id)

        #expect(model.synchronizeSelectedProductPhotos(ids))
        #expect(model.selectedPhotoIDs == ids)
        #expect(model.output == nil)
        let information = try #require(model.informationOutput)
        #expect(information.selectedPhotos == ordered)
        #expect(information.representativePhotoID == ids.first)
        #expect(information.detailPhotos == model.detailPhotos)
        #expect(information.sessionID == model.input.sessionID)
        #expect(information.garmentID == model.input.garmentID)

        #expect(!model.synchronizeSelectedProductPhotos(ids + [ids[0]]))
        #expect(!model.synchronizeSelectedProductPhotos(Array(ids.dropLast()) + [UUID()]))
        #expect(model.selectedPhotoIDs == ids)
        #expect(model.informationOutput == information)
        #expect(model.allPhotosOutput?.selectedPhotos == model.selectablePhotos)

        let repairedIDs = Array(ids.prefix(10))
        #expect(model.synchronizeSelectedProductPhotos(repairedIDs))
        #expect(model.output?.selectedPhotos.map(\.id) == repairedIDs)
        #expect(model.informationOutput == model.output)
        #expect(model.allPhotosOutput?.selectedPhotos == model.selectablePhotos)
    }

    private func makeModel() async throws -> ProductPhotoModel {
        let seed = CapturedAsset(id: UUID(), sessionID: UUID(), garmentID: UUID(),
            purpose: .measurement, capturedAt: .now, source: .mockPlaceholder)
        let model = try ProductPhotoModel(input: .init(sessionID: seed.sessionID,
            garmentID: seed.garmentID, measurement: seed),
            captureProvider: MockCameraService(purpose: .detail))
        for _ in 0..<11 { try await model.captureDetail() }
        return model
    }
}
