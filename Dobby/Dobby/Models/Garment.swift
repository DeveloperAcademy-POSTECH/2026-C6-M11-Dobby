//
//  Garment.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData

/// 상품 한 벌. 앱의 중심이 되는 레코드다.

@Model
final class Garment {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    /// 확인한 LiDAR 보관 기록. 같은 기록을 다시 전달해도 상품을 중복 생성하지 않는다.
    var sourceMeasurementID: UUID? = nil
    /// 사진·치수와 제품 정보 입력을 저장한 시점. nil이면 새 연결 흐름의 초안이다.
    var informationCompletedAt: Date? = nil
    /// 나가기를 눌러 보관한 등록 과정. 과거 상품의 nil은 초안으로 취급하지 않는다.
    var creationDraftData: Data? = nil
    /// 전체 촬영 사진의 최초 상품 반영 시점. 재진입 시 편집한 사진 순서·제외 상태를 보존한다.
    var capturePhotosAppliedAt: Date? = nil

    // MARK: 분류 — 모델이 채운다

    /// 분류 모델이 고른 15종 중 하나. `"Sweater"` 처럼 원문 그대로 둔다. 화면 표시용이다.
    var category: String
    /// 실측 항목을 결정하는 값. `GarmentGroup`의 rawValue.
    ///
    /// `category`와 따로 두는 이유는, 스웨터든 후디든 자켓이든 **치수 항목은 똑같이 상의 6개**
    /// 이기 때문이다. 화면에는 "스웨터"라고 보여주고 계산은 "상의"로 한다.
    var groupRaw: String

    // MARK: 사용자 입력

    var name: String
    var brand: String
    var detail: String
    var price: Int?

    /// Optional metadata survives completion; old products have no AI sources.
    var aiSourcesData: Data? = nil

    /// 내보내기 화면에서 선택한 플랫폼. 기존 상품은 nil이며 업로드 성공 기록과 구분한다.
    var selectedExportChannelRawValues: [String]? = nil

    // MARK: 필터용 사본
    //
    // 필터 화면의 "총장 60\~70cm" 같은 범위 검색을 위해 `measurements` 안의 값을 복사해 둔다.
    // 관계 배열 안쪽 값으로는 `#Predicate` 범위 비교가 어렵고, 되더라도 상품이 늘면 느려진다.
    // 중복 저장이지만 필터가 있는 한 이쪽이 실용적이다. 치수가 바뀔 때마다
    // `syncFilterFields()`로 맞춰야 하며, 그 호출은 `Measurement` 안에 들어 있다.

    var lengthCm: Double?      // 총장 — 세 종류 모두
    var shoulderCm: Double?    // 어깨 — 상의
    var chestCm: Double?       // 가슴 — 상의
    var sleeveCm: Double?      // 표시하는 한쪽 소매 — 상의
    var waistCm: Double?       // 허리 — 바지·스커트

    // MARK: 관계

    @Relationship(deleteRule: .cascade, inverse: \GarmentPhoto.garment)
    var photos: [GarmentPhoto] = []

    @Relationship(deleteRule: .cascade, inverse: \MeasuredValue.garment)
    var measurements: [MeasuredValue] = []

    @Relationship(deleteRule: .cascade, inverse: \ExportRecord.garment)
    var exports: [ExportRecord] = []

    init(category: String, group: GarmentGroup, name: String = "",
         brand: String = "", detail: String = "", price: Int? = nil) {
        self.id = UUID()
        self.createdAt = .now
        self.updatedAt = .now
        self.category = category
        self.groupRaw = group.rawValue
        self.name = name
        self.brand = brand
        self.detail = detail
        self.price = price
    }

    var group: GarmentGroup {
        get { GarmentGroup(rawValue: groupRaw) ?? .top }
        set { groupRaw = newValue.rawValue }
    }
}

// MARK: - 읽기 편의

extension Garment {
    var aiSources: [ProductAutofillSource] {
        get {
            guard let aiSourcesData, aiSourcesData.count <= 16 * 1024,
                  let sources = try? JSONDecoder().decode([ProductAutofillSource].self, from: aiSourcesData),
                  sources.count <= 3, sources.allSatisfy({ $0.publicURL != nil }) else { return [] }
            return sources
        }
        set {
            let sources = Array(newValue.filter { $0.publicURL != nil }.prefix(3))
            aiSourcesData = sources.isEmpty ? nil : try? JSONEncoder().encode(sources)
        }
    }

    var creationDraft: ProductCreationDraft? {
        guard let creationDraftData,
              let draft = try? JSONDecoder().decode(ProductCreationDraft.self, from: creationDraftData),
              draft.schemaVersion == 1,
              draft.photoState.map({ $0.garmentID == id }) ?? true else { return nil }
        return draft
    }

    var isCreationDraft: Bool { informationCompletedAt == nil && creationDraft != nil }

    /// 관계 배열은 저장 순서를 보장하지 않으므로 읽을 때마다 정렬한다. 화면에서는 `photos`가
    /// 아니라 반드시 이쪽을 쓴다.
    var orderedPhotos: [GarmentPhoto] {
        photos.sorted { $0.order < $1.order }
    }

    /// 원본 실측 사진은 보존하되, 사용자가 제품 사진에서 제외할 수 있다.
    /// 기존 상품의 nil 값은 선택된 사진으로 취급한다.
    var productPhotos: [GarmentPhoto] {
        orderedPhotos.filter { $0.isSelectedForProduct != false }
    }

    var orderedMeasurements: [MeasuredValue] {
        measurements.sorted { $0.displayOrder < $1.displayOrder }
    }

    /// 화면과 내보내기에는 좌우 중 한쪽만 사용하고, 양쪽 원본은 관계 배열에 보존한다.
    var visibleMeasurements: [MeasuredValue] {
        if sourceMeasurementID != nil {
            return GarmentMeasurementPresentation.productMeasurements(orderedMeasurements,
                isTop: group == .top, key: { $0.key })
        }
        return GarmentMeasurementPresentation.visibleMeasurements(orderedMeasurements,
            id: { $0.key }, isUsable: { $0.valueCm.isFinite && $0.valueCm > 0 })
    }

    var thumbnail: GarmentPhoto? {
        productPhotos.first { $0.role == .thumbnail } ?? productPhotos.first
    }

    /// 상품별 선택 이력과 기존 내보내기 성공 기록을 중복 없이 표시한다.
    var selectedExportChannels: [ExportChannel] {
        let selected = Set(selectedExportChannelRawValues ?? [])
        return ExportChannel.availableCases.filter { selected.contains($0.rawValue) || hasExported(to: $0) }
    }

    /// 실측에 쓴 사진. 「지점 다시 잡기」 화면이 이 사진과 그 점들을 연다.
    var measurementPhoto: GarmentPhoto? {
        photos.first(where: \.isMeasurementSource)
    }

    func measurement(_ key: String) -> MeasuredValue? {
        measurements.first { $0.key == key }
    }

    /// 사람이 손댄 흔적이 있는지. 숫자를 고쳤거나 점을 옮겼거나.
    /// 보관함 표시를 다르게 하거나, 재학습용 사례를 모을 때 쓴다.
    var wasCorrectedByHand: Bool {
        measurements.contains { $0.isEdited }
            || (measurementPhoto?.landmarks.contains { $0.isMoved } ?? false)
    }
}

// MARK: - 필터용 사본 관리

extension Garment {
    /// 필터용 사본을 `measurements`의 현재 값으로 맞춘다. 치수가 바뀐 뒤에 부른다.
    ///
    /// 바지·스커트에는 어깨가 없고 상의에는 허리가 없으므로, 해당 없는 값은 nil로 남는다.
    /// 필터 쪽에서 "범위가 걸렸는데 값이 nil이면 제외"로 다룬다.
    func syncFilterFields() {
        let selected = visibleMeasurements.filter { $0.valueCm.isFinite && $0.valueCm > 0 }
        lengthCm = selected.first { $0.key == "totalLength" }?.valueCm
            ?? selected.first { $0.key == "totalLengthLeft" || $0.key == "totalLengthRight" }?.valueCm
        shoulderCm = selected.first { $0.key == "shoulderWidth" }?.valueCm
        chestCm = selected.first { $0.key == "chestWidth" }?.valueCm
        sleeveCm = selected.first { $0.key == "sleeveLengthLeft" || $0.key == "sleeveLengthRight" }?.valueCm
        waistCm = selected.first { $0.key == "waistWidth" }?.valueCm
        updatedAt = .now
    }
}
