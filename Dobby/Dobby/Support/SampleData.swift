//  SampleData.swift
//
//  역할: 화면을 만들 때 쓰는 더미 상품. 미리보기용 메모리 저장소와, 실제 저장소에 채워 넣는
//        함수를 함께 둔다. 사진은 파일이 있어야 목록이 제대로 보이므로 단색 이미지를 만들어 쓴다.
//  쓰이는 곳: SwiftUI 미리보기 · 개발 중 보관함 채우기
//

//  미리보기 전용이라 #if DEBUG로 감싼다. 배포 빌드에는 포함되지 않는다.
//

#if DEBUG
import Foundation
import SwiftData
import SwiftUI

enum SampleData {
    static let exportSampleID = UUID(uuidString: "53E00000-0000-4000-8000-000000000053")!

    /// 미리보기용 저장소. `isStoredInMemoryOnly`라 디스크에 남지 않는다.
    @MainActor
    static var previewContainer: ModelContainer = {
        let container = try! ModelContainer(
            for: Garment.self, GarmentPhoto.self, LandmarkPoint.self,
                 MeasuredValue.self, ExportRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        seed(into: container.mainContext)
        return container
    }()

    /// 이미 상품이 있으면 아무것도 하지 않는다. 앱을 다시 켤 때마다 쌓이지 않게 하려는 것이다.
    static func seed(into context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<Garment>())) ?? 0
        guard existing == 0 else { return }
        for item in items {
            insert(item, into: context)
        }
    }

    /// 미리보기에서 상품 하나를 꺼내 쓸 때. 비어 있으면 채우고 첫 건을 돌려준다.
    static func first(in context: ModelContext) -> Garment {
        seed(into: context)
        let descriptor = FetchDescriptor<Garment>(sortBy: [SortDescriptor(\.createdAt)])
        if let existing = try? context.fetch(descriptor).first { return existing }
        let fallback = Garment(category: "Jacket", group: .top, name: "샘플 상품")
        context.insert(fallback)
        return fallback
    }

    /// 보관함에서 실제 내보내기 흐름을 확인할 때 쓰는 단일 상품이다.
    /// 고정 ID를 사용해 버튼을 여러 번 눌러도 상품이 중복 생성되지 않는다.
    @MainActor
    static func exportSample(in context: ModelContext) throws -> Garment {
        let descriptor = FetchDescriptor<Garment>(
            predicate: #Predicate { $0.id == exportSampleID }
        )
        if let existing = try context.fetch(descriptor).first {
            try upgradeExportSampleIfNeeded(existing, in: context)
            return existing
        }

        let garment = insert(exportSampleItem, id: exportSampleID, into: context)
        garment.informationCompletedAt = .now
        try context.save()
        return garment
    }

    /// 예전 버전에서 한 장만 저장된 내보내기 샘플도 앱을 다시 열면 최신 상태로 맞춘다.
    @MainActor
    static func refreshExportSampleIfPresent(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<Garment>(
            predicate: #Predicate { $0.id == exportSampleID }
        )
        guard let existing = try context.fetch(descriptor).first else { return }
        try upgradeExportSampleIfNeeded(existing, in: context)
    }

    /// 상세 화면이 이미 열려 있는 경우에도 관계 배열을 직접 갱신해 새 사진이 바로 보이게 한다.
    @MainActor
    static func upgradeExportSampleIfNeeded(_ garment: Garment, in context: ModelContext) throws {
        guard garment.id == exportSampleID else { return }
        try ensurePlaceholderPhotos(colors: exportSampleItem.colors, for: garment)
        try context.save()
    }

    // MARK: 더미 목록

    private struct Item {
        let category: String
        let group: GarmentGroup
        let name: String
        let brand: String
        let detail: String
        let price: Int?
        let colors: [UIColor]
        /// (key, 표기, 자동값, 사람이 고친 값)
        let sizes: [(String, String, Double, Double?)]
    }

    private static let trackTopColors: [UIColor] = [
        UIColor(red: 0.12, green: 0.18, blue: 0.35, alpha: 1),
        UIColor(red: 0.82, green: 0.18, blue: 0.22, alpha: 1),
        UIColor(red: 0.95, green: 0.42, blue: 0.12, alpha: 1),
        UIColor(red: 0.93, green: 0.72, blue: 0.14, alpha: 1),
        UIColor(red: 0.22, green: 0.62, blue: 0.28, alpha: 1),
        UIColor(red: 0.10, green: 0.62, blue: 0.62, alpha: 1),
        UIColor(red: 0.16, green: 0.42, blue: 0.82, alpha: 1),
        UIColor(red: 0.42, green: 0.24, blue: 0.72, alpha: 1),
        UIColor(red: 0.78, green: 0.22, blue: 0.58, alpha: 1),
        UIColor(red: 0.34, green: 0.36, blue: 0.40, alpha: 1)
    ]

    private static let items: [Item] = [
        Item(category: "Jacket", group: .top,
             name: "90s 나이키 트랙탑", brand: "나이키",
             detail: "소매 끝 약간 늘어남. 지퍼 정상.", price: 89_000,
             colors: trackTopColors,
             sizes: [("shoulderWidth", "어깨", 56.0, nil),
                     ("chestWidth", "가슴", 55.0, nil),
                     ("totalLength", "총장", 68.0, nil),
                     ("sleeveLengthLeft", "소매", 52.0, 54.0)]),

        Item(category: "Sweater", group: .top,
             name: "빈티지 울 니트", brand: "유니클로",
             detail: "보풀 약간.", price: 45_000,
             colors: [UIColor(red: 0.62, green: 0.40, blue: 0.24, alpha: 1)],
             sizes: [("shoulderWidth", "어깨", 48.0, nil),
                     ("chestWidth", "가슴", 52.0, nil),
                     ("totalLength", "총장", 64.0, nil),
                     ("sleeveLengthLeft", "소매", 58.0, nil)]),

        Item(category: "T-shirt", group: .top,
             name: "80s 프린트 티셔츠", brand: "챔피온",
             detail: "프린트 갈라짐 있음. 빈티지 느낌.", price: 32_000,
             colors: [UIColor(red: 0.85, green: 0.24, blue: 0.28, alpha: 1)],
             sizes: [("shoulderWidth", "어깨", 45.0, nil),
                     ("chestWidth", "가슴", 50.0, nil),
                     ("totalLength", "총장", 66.0, nil),
                     ("sleeveLengthLeft", "소매", 20.0, nil)]),

        Item(category: "Jeans", group: .pants,
             name: "리바이스 501 데님", brand: "리바이스",
             detail: "밑단 셀비지. 워싱 양호.", price: 120_000,
             colors: [UIColor(red: 0.25, green: 0.35, blue: 0.52, alpha: 1)],
             sizes: [("waistWidth", "허리", 40.0, nil),
                     ("rise", "밑위", 28.0, nil),
                     ("hemWidthLeft", "밑단", 21.0, nil),
                     ("totalLengthLeft", "총장", 102.0, nil)]),

        Item(category: "Shorts", group: .pants,
             name: "코튼 버뮤다 쇼츠", brand: "무지",
             detail: "", price: 28_000,
             colors: [UIColor(red: 0.78, green: 0.74, blue: 0.62, alpha: 1)],
             sizes: [("waistWidth", "허리", 38.0, nil),
                     ("rise", "밑위", 26.0, nil),
                     ("hemWidthLeft", "밑단", 26.0, nil),
                     ("totalLengthLeft", "총장", 48.0, nil)]),

        Item(category: "Skirt", group: .skirt,
             name: "플리츠 미디 스커트", brand: "",
             detail: "허리 밴드 탄력 양호.", price: nil,
             colors: [UIColor(red: 0.20, green: 0.22, blue: 0.24, alpha: 1)],
             sizes: [("waistWidth", "허리", 34.0, nil),
                     ("hemWidth", "밑단", 62.0, nil),
                     ("totalLength", "총장", 72.0, nil)]),
    ]

    private static let exportSampleItem = Item(
        category: "Jacket",
        group: .top,
        name: "90s 나이키 트랙탑",
        brand: "나이키",
        detail: "소매 끝에 자연스러운 사용감이 있으며 지퍼는 정상 작동합니다.",
        price: 89_000,
        colors: trackTopColors,
        sizes: [
            ("shoulderWidth", "어깨", 56.0, nil),
            ("chestWidth", "가슴", 55.0, nil),
            ("totalLength", "총장", 68.0, nil),
            ("sleeveLengthLeft", "소매", 52.0, nil)
        ]
    )

    @discardableResult
    private static func insert(_ item: Item, id: UUID? = nil, into context: ModelContext) -> Garment {
        let garment = Garment(category: item.category, group: item.group, name: item.name,
                              brand: item.brand, detail: item.detail, price: item.price)
        if let id { garment.id = id }
        context.insert(garment)

        for (index, size) in item.sizes.enumerated() {
            let value = MeasuredValue(key: size.0, label: size.1, displayOrder: index,
                                      valueCm: size.3 ?? size.2, autoValueCm: size.2)
            // 네 번째 값이 있으면 사람이 고친 상품이다. 보관함에서 표시가 다르게 나오는지 확인용.
            value.isEdited = size.3 != nil
            garment.measurements.append(value)
        }

        try? ensurePlaceholderPhotos(colors: item.colors, for: garment)
        garment.syncFilterFields()
        // 등록 시각을 조금씩 벌려 두어야 최신순 정렬이 눈에 보인다.
        garment.createdAt = .now.addingTimeInterval(-Double(items.count) * 3_600)
        return garment
    }

    /// 실제 사진 대신 단색 이미지를 만들어 저장한다. 목록이 비어 보이지 않게 하려는 것뿐이다.
    private static func ensurePlaceholderPhotos(colors: [UIColor], for garment: Garment) throws {
        let existingCount = garment.orderedPhotos.count
        guard existingCount < colors.count else { return }
        for index in existingCount..<colors.count {
            let photo = try addPlaceholderPhoto(color: colors[index], to: garment,
                                                isFirst: index == 0)
            if index == 0 {
                photo.garmentScore = 0.92
                photo.pixelsPerCm = 12.4
            }
        }
    }

    private static func addPlaceholderPhoto(color: UIColor, to garment: Garment,
                                            isFirst: Bool) throws -> GarmentPhoto {
        let size = CGSize(width: 600, height: 800)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try GarmentStore.addPhoto(image, to: garment,
                                         role: isFirst ? .thumbnail : .detail,
                                         isMeasurementSource: isFirst)
    }
}
#endif
