#if DEBUG
import Foundation
import SwiftData
import UIKit

/// Shared by library previews only; never seeds the app's persistent store.
@MainActor
enum LibraryPreviewData {
    static let container = makeContainer()

    /// Interactive previews receive their own data so deletion stays local.
    static func makeContainer() -> ModelContainer {
        do {
            let container = try ModelContainer(
                for: Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                     MeasuredValue.self, ExportRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            let context = container.mainContext
            let timestamp = Date(timeIntervalSince1970: 1_790_000_000)

            for (index, item) in items.enumerated() {
                guard let url = Bundle.main.url(forResource: item.imageName, withExtension: "png"),
                      let image = UIImage(contentsOfFile: url.path) else {
                    preconditionFailure("보관함 미리보기 이미지가 없습니다: \(item.imageName).png")
                }
                let garment = Garment(category: item.category, group: .top,
                    name: item.name, brand: item.brand, price: item.price)
                context.insert(garment)
                try GarmentStore.addPhoto(image, to: garment, role: .thumbnail)
                garment.selectedExportChannelRawValues = [
                    ExportChannel.instagram, .cafe24, .fruitsFamily
                ].map(\.rawValue)
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

    private static let items = [
        Item(category: "Jacket",
            name: "베이프 BAPE A Bathing Ape 황계 카모플라주 후드 셔츠 자켓",
            brand: "Bape", price: 155_000, imageName: "library-preview-bape"),
        Item(category: "Sweater",
            name: "아워레가시 Our Legacy 팝 오버 니트",
            brand: "Our Legacy", price: 165_000, imageName: "library-preview-knit"),
        Item(category: "Jacket",
            name: "폴로 랄프로렌 Polo Ralph Lauren 폴리쉘 자켓",
            brand: "Polo Ralph Lauren", price: 89_000, imageName: "library-preview-polo-jacket"),
        Item(category: "Shirt",
            name: "폴로 랄프로렌 Polo Ralph Lauren 헌팅 플란넬 체크 레더패치 셔츠",
            brand: "Polo Ralph Lauren", price: 180_000, imageName: "library-preview-polo-shirt")
    ]
}
#endif
