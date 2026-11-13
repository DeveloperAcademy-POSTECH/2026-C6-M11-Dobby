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

/// 상품으로 전달할 사진 결과. 선택 화면을 생략하는 흐름에서는 전체 촬영 사진을 담는다.
struct ProductPhotoOutput: Equatable, Sendable {
    let sessionID: UUID
    let garmentID: UUID
    let detailPhotos: [CapturedAsset]
    /// 기존 선택 흐름은 선택 순서, 전체 전달 흐름은 실측 원본·표시본·상세 촬영 순서다.
    let selectedPhotos: [CapturedAsset]
    let representativePhotoID: UUID
    /// 촬영 갤러리에서 삭제한 사진. 사진 앱 원본 삭제 요청이 아니다.
    var deletedPhotoIDs: Set<UUID> = []
}
