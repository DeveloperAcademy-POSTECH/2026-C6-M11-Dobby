#if DEBUG
import Foundation
import SwiftData
import UIKit

/// Shared by library previews only; never seeds the app's persistent store.
@MainActor
enum LibraryPreviewData {
    static let container = makeContainer()

    /// Interactive previews receive their own data so deletion stays local.
    static func makeContainer(includesDraft: Bool = false) -> ModelContainer {
        do {
            let container = try ModelContainer(
                for: Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                     MeasuredValue.self, ExportRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = container.mainContext
            let timestamp = Date(timeIntervalSince1970: 1_790_000_000)

            if includesDraft {
                try insertDraft(in: context, savedAt: timestamp.addingTimeInterval(60))
            }

            for (index, item) in items.enumerated() {
                guard let url = Bundle.main.url(forResource: item.imageName, withExtension: "png"),
                      let image = UIImage(contentsOfFile: url.path) else {
                    preconditionFailure("보관함 미리보기 이미지가 없습니다: \(item.imageName).png")
                }
                let garment = Garment(category: item.category, group: .top,
                    name: item.name, brand: item.brand, price: item.price)
                context.insert(garment)
                try GarmentStore.addPhoto(image, to: garment, role: .thumbnail)
                garment.exports = [
                    ExportChannel.instagram, .cafe24, .fruitsFamily
                ].map { ExportRecord(channel: $0, succeeded: true) }
                let date = timestamp.addingTimeInterval(-Double(index))
                garment.createdAt = date
                garment.updatedAt = date
                garment.informationCompletedAt = date
            }
            try context.save()
            return container
        } catch {
            preconditionFailure("보관함 미리보기 데이터를 준비하지 못했습니다: \(error)")
        }
    }

    static var garments: [Garment] {
        do {
            return try container.mainContext.fetch(FetchDescriptor<Garment>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
        } catch {
            preconditionFailure("보관함 미리보기 상품을 불러오지 못했습니다: \(error)")
        }
    }

    private struct Item {
        let category: String
        let name: String
        let brand: String
        let price: Int
        let imageName: String
    }

    private static func insertDraft(in context: ModelContext, savedAt: Date) throws {
        let item = items[0]
        guard let url = Bundle.main.url(forResource: item.imageName, withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            preconditionFailure("보관함 임시저장 미리보기 이미지가 없습니다: \(item.imageName).png")
        }
        let measurementRecordID = UUID()
        let garment = Garment(category: item.category, group: .top)
        garment.sourceMeasurementID = measurementRecordID
        context.insert(garment)
        try GarmentStore.addPhoto(image, to: garment, role: .thumbnail)
        garment.creationDraftData = try JSONEncoder().encode(ProductCreationDraft(
            step: .information,
            measurementRecordID: measurementRecordID,
            photoState: nil,
            measurementInputData: nil,
            savedAt: savedAt
        ))
        garment.createdAt = savedAt
        garment.updatedAt = savedAt
    }

    private static let items = [
        Item(category: "Jacket",
            name: "황계 카모플라주 후드 셔츠 자켓",
            brand: "Bape", price: 155_000, imageName: "library-preview-bape"),
        Item(category: "Sweater",
            name: "팝오버 니트",
            brand: "Our Legacy", price: 165_000, imageName: "library-preview-knit"),
        Item(category: "Jacket",
            name: "폴리쉘 자켓",
            brand: "Polo Ralph Lauren", price: 89_000, imageName: "library-preview-polo-jacket"),
        Item(category: "Shirt",
            name: "헌팅 플란넬 체크 레더패치 셔츠",
            brand: "Polo Ralph Lauren", price: 180_000, imageName: "library-preview-polo-shirt")
    ]
}
#endif
