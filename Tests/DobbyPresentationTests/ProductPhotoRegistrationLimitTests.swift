import Foundation
import SwiftData
import Testing
@testable import Dobby

@MainActor
struct ProductPhotoRegistrationLimitTests {
    @Test(arguments: [0, 9, 10, 11, 23])
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
            #expect((1...10).contains(count) && saves == 1 && drafts.isEmpty)
            #expect(length.valueCm == 73 && garment.informationCompletedAt != nil)
            #expect(length.autoValueCm == 68.25)
        } catch {
            #expect(count == 0 || count > 10)
            #expect(saves == 0 && drafts[length.id] == "72.5")
            #expect(length.valueCm == 68.25 && garment.informationCompletedAt == nil)
        }
        #expect(Set(garment.photos.map(\.id)) == photoIDs, "Validation must never remove source photos")
        #expect(garment.orderedPhotos.map(\.id) == orderedPhotoIDs, "The explicit order field, not SwiftData relationship array order, determines presentation")
        #expect(garment.productPhotos.count == count)
    }

    @Test(arguments: [0, 9, 10, 11, 23])
    func completionAvailabilityKeepsPartialInformationAttemptsWithinPhotoLimit(count: Int) {
        let garment = Garment(category: "Jacket", group: .top)
        garment.photos = (0..<count).map {
            GarmentPhoto(fileName: "availability-\($0).jpg", role: $0 == 0 ? .thumbnail : .detail, order: $0)
        }
        #expect(!GarmentInformationValidation.canAttemptCompletion(garment))

        garment.name = "자켓"
        #expect(GarmentInformationValidation.canAttemptCompletion(garment) == (count <= 10))
        #expect(!GarmentInformationValidation.isValid(garment), "Partial information must still be validated after tapping Done")

        garment.detail = "설명"
        garment.price = 40000
        #expect(GarmentInformationValidation.canAttemptCompletion(garment) == (count <= 10))
        #expect(GarmentInformationValidation.isValid(garment) == (1...10).contains(count))
    }

    @Test func completionAvailabilityPreservesExistingOptionalAndInvalidFieldAttempts() {
        let garment = Garment(category: "Jacket", group: .top)
        garment.photos = [GarmentPhoto(fileName: "partial.jpg", role: .thumbnail, order: 0)]
        garment.name = " \n "
        garment.detail = "\t"
        garment.brand = " "
        #expect(!GarmentInformationValidation.canAttemptCompletion(garment))

        garment.brand = "브랜드"
        #expect(GarmentInformationValidation.canAttemptCompletion(garment))
        #expect(!GarmentInformationValidation.isValid(garment), "An optional brand still enables required-field validation on tap")
        garment.brand = ""
        garment.price = 0
        #expect(GarmentInformationValidation.canAttemptCompletion(garment))
        #expect(!GarmentInformationValidation.isValid(garment), "An entered invalid price must not hide required-field errors behind a disabled button")
    }

    @Test(arguments: [11, 23])
    func removingOverflowRestoresCompletionWithoutDiscardingOriginals(count: Int) throws {
        let container = try ModelContainer(for: ProductAppStorage.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let garment = Garment(category: "Jacket", group: .top, name: "자켓", detail: "설명", price: 40000)
        garment.photos = (0..<count).map {
            GarmentPhoto(fileName: "repair-\($0).jpg", role: $0 == 0 ? .thumbnail : .detail, order: $0)
        }
        context.insert(garment)
        let originalIDs = Set(garment.photos.map(\.id))
        let removedIDs = Array(garment.productPhotos.prefix(count - 10).map(\.id))
        #expect(!GarmentInformationValidation.canAttemptCompletion(garment))
        #expect(!GarmentInformationValidation.isValid(garment))

        for id in removedIDs {
            #expect(try GarmentStore.removeProductPhoto(id: id, from: garment, in: context, persist: { _ in }))
            #expect(GarmentInformationValidation.canAttemptCompletion(garment) == (garment.productPhotos.count <= 10))
        }
        #expect(garment.productPhotos.count == 10)
        #expect(GarmentInformationValidation.canAttemptCompletion(garment))
        #expect(GarmentInformationValidation.isValid(garment))
        #expect(Set(garment.photos.map(\.id)) == originalIDs, "Repair removes registrations while retaining every camera original")
        #expect(Set(garment.productPhotos.map(\.id)).isDisjoint(with: removedIDs))

        garment.detail = ""
        #expect(GarmentInformationValidation.canAttemptCompletion(garment), "Returning to the limit restores the existing partial-field tap behavior")
        #expect(!GarmentInformationValidation.isValid(garment))
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
        #expect(ProductPhotoLimit.registrationIDs(existing: legacy, incoming: [ids[12]]) == legacy + [ids[12]])
        #expect(ProductPhotoLimit.registrationIDs(existing: [ids[0]], incoming: [ids[0], ids[1], ids[1]]) == [ids[0], ids[1]])
    }
}
