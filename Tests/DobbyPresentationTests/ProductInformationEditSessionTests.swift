// Created by mason on 10/30/26.
import Foundation
import SwiftData
import Testing
@testable import Dobby

@MainActor
struct ProductInformationEditSessionTests {
    @Test func discardAndAbandonedSessionPreserveStoredProduct() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        #expect(!session.hasChanges)
        #expect(!session.context.autosaveEnabled)
        session.garment.name = "변경"
        session.garment.photos[0].isSelectedForProduct = false
        session.garment.photos[0].role = .detail
        session.measurementInput.setText("72.19", for: session.garment.measurements[0])
        #expect(session.hasChanges)
        #expect(fixture.original.name == "원본")
        try fixture.container.mainContext.save() // 다른 화면의 저장도 편집본을 저장하지 않는다.
        try fixture.assertOriginalInStore()
        session.discard()
        try fixture.assertOriginalInStore()
    }

    @Test func completionPersistsAndRefreshesExistingDetail() throws {
        let fixture = try Fixture()
        fixture.original.photos.append(GarmentPhoto(fileName: "remaining.jpg", role: .detail, order: 1))
        try fixture.container.mainContext.save()
        let session = try fixture.session()
        session.garment.name = "저장"
        session.garment.brand = " \n "
        session.garment.photos[0].isSelectedForProduct = false
        session.measurementInput.setText("72.19", for: session.garment.measurements[0])
        try GarmentInputCompletion.save(garment: session.garment, drafts: &session.measurementInput.drafts) {
            try session.context.save()
        }
        session.reflectSavedChanges(in: fixture.original)
        #expect(fixture.original.name == "저장")
        #expect(fixture.original.productPhotos.count == 1)
        #expect(fixture.original.measurements[0].valueCm == 72.1)
        let reopened = try fixture.session()
        #expect(reopened.garment.name == "저장")
        #expect(reopened.garment.brand == " \n ") // No Brand는 저장값이 아니다.
        #expect(reopened.garment.productPhotos.count == 1)
        #expect(reopened.garment.measurements[0].valueCm == 72.1)
        #expect(reopened.garment.informationCompletedAt != nil)
    }

    @Test func failedSaveKeepsEditsWithoutChangingPersistedProduct() throws {
        let fixture = try Fixture()
        let session = try fixture.session()
        session.garment.name = "재시도"
        #expect(throws: CocoaError.self) {
            try GarmentInputCompletion.save(garment: session.garment, drafts: &session.measurementInput.drafts) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        #expect(session.garment.name == "재시도")
        #expect(session.hasChanges)
        try fixture.assertOriginalInStore()
    }

    private struct Fixture {
        let container: ModelContainer
        let original: Garment
        init() throws {
            let schema = ProductAppStorage.schema
            container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            ])
            original = Garment(category: "Jacket", group: .top, name: "원본", detail: "설명", price: 100)
            original.photos = [GarmentPhoto(fileName: "preserved.jpg", role: .thumbnail, order: 0)]
            original.measurements = [MeasuredValue(key: "chestWidth", label: "가슴", displayOrder: 0,
                                                   valueCm: 55, autoValueCm: 55)]
            container.mainContext.insert(original)
            try container.mainContext.save()
        }
        func session() throws -> ProductInformationEditSession {
            try ProductInformationEditSession(garmentID: original.id, container: container)
        }
        func assertOriginalInStore() throws {
            let stored = try session().garment
            #expect(stored.name == "원본")
            #expect(stored.productPhotos.count == 1)
            #expect(stored.photos[0].role == .thumbnail)
            #expect(stored.measurements[0].valueCm == 55)
        }
    }
}
