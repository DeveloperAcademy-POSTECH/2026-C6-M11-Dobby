//
//  ProductPhotoHandoff.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import Foundation

/// 실측의 영구 원본에서 변환한 상세 촬영 입력.
/// 제품/세션 ID는 이전 단계가 생성하며, 이 기능에서는 새로 만들지 않는다.
struct ProductPhotoInput: Equatable, Sendable {
    let sessionID: UUID
    let garmentID: UUID
    let measurement: CapturedAsset
    var measurementVisualization: CapturedAsset? = nil

    var measurementPhotos: [CapturedAsset] {
        [measurement] + [measurementVisualization].compactMap { $0 }
    }
}

/// 사진 선택의 완료 결과. ProductPhotoHandoff가 선택 사진을 같은 상품의 저장소로 복사한다.
struct ProductPhotoOutput: Equatable, Sendable {
    let sessionID: UUID
    let garmentID: UUID
    let detailPhotos: [CapturedAsset]
    /// 선택 순서대로 전달한다. 미선택 상세 사진도 detailPhotos에는 남는다.
    let selectedPhotos: [CapturedAsset]
    let representativePhotoID: UUID
}
