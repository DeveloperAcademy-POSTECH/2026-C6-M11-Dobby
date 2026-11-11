//
//  GarmentPhoto.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData

/// 사진 한 장. 이미지 파일은 `Documents/photos/`에 두고 여기에는 파일명만 남긴다.

@Model
final class GarmentPhoto {
    @Attribute(.unique) var id: UUID
    /// `"<상품id>-8c1d.jpg"`. 앞에 상품 id를 붙여 파일만 봐도 주인을 알 수 있게 한다.
    var fileName: String
    var roleRaw: String
    /// 사용자가 끌어서 바꾼 순서. 관계 배열이 순서를 지켜주지 않아 직접 들고 있어야 한다.
    var order: Int
    var isSelectedForProduct: Bool? = nil
    /// Product presentation only. Measurement RGB, landmarks and depth stay in their original coordinates.
    var productRotationQuarterTurns: Int? = nil
    var capturedAt: Date

    // MARK: 실측에 쓴 사진에만 채우는 값
    //
    // 디테일 컷은 아래 다섯 개가 전부 nil이다.

    var isMeasurementSource: Bool
    var imageWidth: Int?
    var imageHeight: Int?
    /// 랜드마크 모델의 옷 점수. **스커트 모델은 점수를 내지 않아 nil이 된다.**
    var garmentScore: Double?
    /// 실측 당시의 픽셀↔센티미터 환산 계수.
    ///
    /// 「지점 다시 잡기」에서 점을 옮기면 치수를 다시 계산해야 하는데, 그때 LiDAR를 다시 돌릴
    /// 수는 없다. 옷이 바닥에 평평하게 놓여 있다는 전제 아래 이 계수로 환산하면, 촬영을 다시
    /// 하지 않고도 옮긴 점에서 cm가 나온다.
    var pixelsPerCm: Double?

    /// 보관된 깊이·보정 기록과 연결한다. 픽셀/cm 환산을 추정하지 않는다.
    var measurementRecordID: UUID? = nil
    var measurementSessionID: UUID? = nil
    var measurementFrameID: UUID? = nil
    /// 좌표와 픽셀 크기는 회전하지 않은 원본 RGB 기준이다. JPEG에는 표시 방향을 기록한다.
    var measurementOrientationRaw: String? = nil
    var measurementModelVersion: String? = nil
    var measurementAlgorithmVersion: String? = nil
    var measurementDepthSourceRaw: String? = nil
    var measurementLandmarkOriginRaw: String? = nil

    @Relationship(deleteRule: .cascade, inverse: \LandmarkPoint.photo)
    var landmarks: [LandmarkPoint] = []

    var garment: Garment?

    init(fileName: String, role: PhotoRole, order: Int, isMeasurementSource: Bool = false) {
        self.id = UUID()
        self.fileName = fileName
        self.roleRaw = role.rawValue
        self.order = order
        self.capturedAt = .now
        self.isMeasurementSource = isMeasurementSource
    }

    var role: PhotoRole {
        get { PhotoRole(rawValue: roleRaw) ?? .detail }
        set { roleRaw = newValue.rawValue }
    }

    var orderedLandmarks: [LandmarkPoint] {
        landmarks.sorted { $0.index < $1.index }
    }

    func landmark(_ name: String) -> LandmarkPoint? {
        landmarks.first { $0.name == name }
    }

    /// 0\~1 좌표를 원본 픽셀로. 치수를 다시 계산할 때 쓴다.
    func pixel(for point: LandmarkPoint) -> CGPoint? {
        guard let imageWidth, let imageHeight else { return nil }
        return CGPoint(x: point.x * Double(imageWidth), y: point.y * Double(imageHeight))
    }
}
