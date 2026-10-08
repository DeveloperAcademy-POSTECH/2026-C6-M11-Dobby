//
//  LandmarkPoint.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData

/// 치수 기준점 하나.

@Model
final class LandmarkPoint {
    @Attribute(.unique) var id: UUID
    /// 파이프라인이 쓰는 이름 그대로 — `"shoulder_left"` 등.
    var name: String
    /// 스키마상의 순서. 화면에 번호를 붙이고 정렬하는 데 쓴다.
    var index: Int

    /// 사진 폭·높이로 나눈 0\~1 좌표.
    ///
    /// 픽셀이 아니라 비율로 두면 화면 크기나 확대 배율이 바뀌어도 그대로 쓸 수 있고, 사진
    /// 해상도가 달라도 의미가 유지된다. 픽셀이 필요하면 `GarmentPhoto.pixel(for:)`를 쓴다.
    var x: Double
    var y: Double

    /// 모델이 처음 찍은 자리. **옮겨도 지우지 않는다.**
    ///
    /// 옮긴 거리가 곧 "모델이 이 점을 얼마나 틀렸는가"다. 치수 수정값보다 이쪽이 재학습에 바로
    /// 쓰이는 정보다 — 어느 점이 어디로 가야 했는지가 사진과 함께 그대로 남는다.
    var autoX: Double
    var autoY: Double
    /// nil은 기존 기록처럼 원본 관측이 있음을 뜻한다. false인 수동 복구점의
    /// autoX/Y는 저장 형식을 위한 현재 좌표의 사본이며 원본 관측으로 쓰지 않는다.
    var hasAutomaticObservation: Bool? = nil
    var isMoved: Bool
    /// 사진 좌표와 함께 모델/수동 출처 및 파생점의 입력을 보존한다.
    var originRaw: String? = nil
    var autoOriginRaw: String? = nil
    var confidence: Double? = nil
    var autoConfidence: Double? = nil
    var isVisible: Bool? = nil
    var autoIsVisible: Bool? = nil
    var derivedFrom: [String]? = nil
    var autoDerivedFrom: [String]? = nil

    var photo: GarmentPhoto?

    init(name: String, index: Int, x: Double, y: Double) {
        self.id = UUID()
        self.name = name
        self.index = index
        self.x = x
        self.y = y
        self.autoX = x
        self.autoY = y
        self.isMoved = false
    }

    /// 모델이 찍은 자리에서 옮겨진 거리. 사진 크기 대비 비율이다.
    var movedDistance: Double {
        guard isMoved, hasAutomaticObservation != false else { return 0 }
        let dx = x - autoX, dy = y - autoY
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 사진 밖으로 나가지 않도록 0\~1로 가둔다.
    func move(toX newX: Double, y newY: Double) {
        x = min(1, max(0, newX))
        y = min(1, max(0, newY))
        isMoved = true
        originRaw = LandmarkOrigin.manual.rawValue
        confidence = nil
        isVisible = true
        photo?.garment?.updatedAt = .now
    }

    func resetToAuto() {
        guard hasAutomaticObservation != false else { return }
        x = autoX
        y = autoY
        isMoved = false
        originRaw = autoOriginRaw
        confidence = autoConfidence
        isVisible = autoIsVisible
        derivedFrom = autoDerivedFrom
        photo?.garment?.updatedAt = .now
    }
}
