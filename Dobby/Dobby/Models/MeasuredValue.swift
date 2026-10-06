//
//  MeasuredValue.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData

@Model
final class MeasuredValue {
    @Attribute(.unique) var id: UUID
    /// 파이프라인의 `GarmentMeasurements`가 쓰는 이름과 같아야 한다 — `"shoulderWidth"` 등.
    /// 양쪽이 어긋나면 결과를 저장할 때마다 이름을 바꾸는 코드가 끼어든다.
    var key: String
    /// 만들 당시의 표기. 나중에 표기를 바꿔도 이미 올린 상품은 그대로 읽히게 둔다.
    var label: String
    var displayOrder: Int

    /// 화면과 내보내기에 쓰는 값. 사람이 고치면 이것만 바뀐다.
    var valueCm: Double
    /// 모델이 처음 낸 값. **고쳐도 지우지 않는다.**
    ///
    /// 이 값과 `valueCm`의 차이가 곧 모델이 얼마나 틀렸는지의 기록이다. 덮어쓰면 사라진다.
    var autoValueCm: Double?
    /// 사용자가 **숫자를 직접** 고쳤는지. 점을 옮겨 다시 계산된 경우는 여기 해당하지 않는다.
    var isEdited: Bool
    /// 원본 LiDAR 결과의 valid/uncertain 상태. 값이 없는 항목은 보관 기록에만 남는다.
    var sourceStatusRaw: String? = nil

    var garment: Garment?

    init(key: String, label: String, displayOrder: Int, valueCm: Double, autoValueCm: Double?) {
        self.id = UUID()
        self.key = key
        self.label = label
        self.displayOrder = displayOrder
        self.valueCm = valueCm
        self.autoValueCm = autoValueCm
        self.isEdited = false
    }

    /// 좌우를 생략한 현재 표시 이름. 저장 당시의 원본 표기는 변경하지 않는다.
    var displayLabel: String {
        GarmentMeasurementPresentation.title(for: key, fallback: label)
    }

    /// 사람이 고친 폭. 모델 오차를 볼 때 쓴다.
    var correctionCm: Double? {
        guard isEdited, let autoValueCm else { return nil }
        return valueCm - autoValueCm
    }

    /// 숫자를 직접 고쳤을 때. 필터용 사본까지 함께 맞춘다.
    func update(to newValue: Double) {
        guard newValue != valueCm else { return }
        valueCm = newValue
        isEdited = true
        garment?.syncFilterFields()
    }

    /// 점을 옮겨서 다시 계산된 값.
    ///
    /// 사람이 숫자를 직접 고친 것은 아니므로 `isEdited`는 건드리지 않는다. 두 가지 수정을
    /// 구분해 두어야 나중에 값이 왜 바뀌었는지 되짚을 수 있다.
    func recalculated(to newValue: Double) {
        valueCm = newValue
        garment?.syncFilterFields()
    }
}
