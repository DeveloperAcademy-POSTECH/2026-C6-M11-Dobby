import Foundation
import SwiftData
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoRegistrationLimitTests {
    @Test(arguments: [0, 10, 11])
    func completionChecksPhotoCountBeforeConsumingInputOrPersisting(count: Int) throws {
        let container = try ModelContainer(for: ProductAppStorage.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top, name: "자켓", detail: "설명", price: 40000)
        garment.photos = (0..<count).map { GarmentPhoto(fileName: "limit-\($0).jpg", role: $0 == 0 ? .thumbnail : .detail, order: $0) }
        let length = MeasuredValue(key: "totalLength", label: "총장", displayOrder: 0, valueCm: 68.25, autoValueCm: 68.25)
        garment.measurements = [length]
        context.insert(garment)
        let photoIDs = Set(garment.photos.map(\.id))
        let orderedPhotoIDs = garment.orderedPhotos.map(\.id)
        var drafts = [length.id: "72.5"]
        var saves = 0
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &drafts) { saves += 1; try context.save() }
            #expect(count == 10 && saves == 1 && drafts.isEmpty)
            #expect(length.valueCm == 72.5 && garment.informationCompletedAt != nil)
        } catch {
            #expect(count == 0 || count == 11)
            #expect(saves == 0 && drafts[length.id] == "72.5")
            #expect(length.valueCm == 68.25 && garment.informationCompletedAt == nil)
        }
        #expect(Set(garment.photos.map(\.id)) == photoIDs, "Validation must never remove source photos")
        #expect(garment.orderedPhotos.map(\.id) == orderedPhotoIDs, "The explicit order field, not SwiftData relationship array order, determines presentation")
        #expect(garment.productPhotos.count == count)
    }

    @Test func removingARegisteredPhotoFreesOneSlotWithoutRemovingItsOriginal() throws {
        let container = try ModelContainer(for: ProductAppStorage.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let garment = Garment(category: "Shirt", group: .top)
        garment.photos = (0..<10).map { GarmentPhoto(fileName: "capacity-\($0).jpg", role: $0 == 0 ? .thumbnail : .detail, order: $0) }
        context.insert(garment)
        let original = garment.photos[0]
        #expect(ProductPhotoLimit.remaining(after: garment.productPhotos.count) == 0)
        #expect(try GarmentStore.removeProductPhoto(id: original.id, from: garment, in: context, persist: { _ in }))
        #expect(garment.photos.count == 10 && garment.photos.contains { $0.id == original.id })
        #expect(ProductPhotoLimit.remaining(after: garment.productPhotos.count) == 1)
        let added = GarmentPhoto(fileName: "replacement.jpg", role: .detail, order: 10)
        added.isSelectedForProduct = true
        garment.photos.append(added)
        #expect(garment.productPhotos.count == 10 && garment.photos.count == 11)
        #expect(ProductPhotoLimit.remaining(after: garment.productPhotos.count) == 0)
    }

    @Test func legacyOverflowIsPreservedForManualRepairAndIncomingIDsStayUnique() {
        let ids = (0..<13).map { _ in UUID() }
        let legacy = Array(ids.prefix(11))
        #expect(ProductPhotoLimit.registrationIDs(existing: legacy, incoming: [ids[12]]) == legacy)
        #expect(ProductPhotoLimit.registrationIDs(existing: [ids[0]], incoming: [ids[0], ids[1], ids[1]]) == [ids[0], ids[1]])
    }
}
