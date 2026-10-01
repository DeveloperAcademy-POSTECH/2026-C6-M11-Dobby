//
//  ProductPhotoHandoff.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import Foundation

/// 임시 화면 입력. 실측 담당자의 공통 Model이 정해지면 진입점에서 변환한다.
/// 제품/세션 ID는 이전 단계가 생성하며, 이 기능에서는 새로 만들지 않는다.
struct ProductPhotoInput: Equatable, Sendable {
    let sessionID: UUID
    let garmentID: UUID
    let measurement: CapturedAsset
}

/// 임시 완료 결과. 파일 소유권을 옮기거나 원본을 삭제하지 않는다.
struct ProductPhotoOutput: Equatable, Sendable {
    let sessionID: UUID
    let garmentID: UUID
    let detailPhotos: [CapturedAsset]
    /// 선택 순서대로 전달한다. 미선택 상세 사진도 detailPhotos에는 남는다.
    let selectedPhotos: [CapturedAsset]
    let representativePhotoID: UUID
}
