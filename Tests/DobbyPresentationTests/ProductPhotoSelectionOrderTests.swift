// Created by mason on 10/4/26.
import Foundation
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoSelectionOrderTests {
    @Test func selectionPartitionKeepsCaptureOrderAndUpdatesRepresentative() async throws {
        let seed = CapturedAsset(id: UUID(), sessionID: UUID(), garmentID: UUID(),
            purpose: .measurement, capturedAt: .now, source: .mockPlaceholder)
        let model = try ProductPhotoModel(input: .init(sessionID: seed.sessionID,
            garmentID: seed.garmentID, measurement: seed),
            captureProvider: MockCameraService(purpose: .detail))
        for _ in 0..<7 { try await model.captureDetail() }
        let ids = model.photos.map(\.id)
        #expect(model.selectionOrderedPhotos.map(\.id) == ids)
        model.toggleSelection(ids[6])
        model.toggleSelection(ids[2])
        #expect(model.selectionOrderedPhotos.map(\.id) == [ids[6], ids[2]] + ids.filter { $0 != ids[6] && $0 != ids[2] })
        #expect(model.output?.representativePhotoID == ids[6])
        model.toggleSelection(ids[6])
        #expect(model.selectionOrderedPhotos.map(\.id) == [ids[2]] + ids.filter { $0 != ids[2] })
        #expect(model.output?.representativePhotoID == ids[2])
        model.toggleSelection(ids[6])
        #expect(model.selectedPhotoIDs == [ids[2], ids[6]])
        model.moveSelection(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.selectionOrderedPhotos.prefix(2).map(\.id) == [ids[6], ids[2]])
        #expect(model.output?.representativePhotoID == ids[6])
        #expect(model.output?.selectedPhotos.map(\.id) == [ids[6], ids[2]])
        model.toggleSelection(ids[6])
        model.toggleSelection(ids[2])
        #expect(model.output == nil)
        #expect(model.selectionOrderedPhotos.map(\.id) == ids)
        #expect(model.photos.map(\.id) == ids)
    }
}
