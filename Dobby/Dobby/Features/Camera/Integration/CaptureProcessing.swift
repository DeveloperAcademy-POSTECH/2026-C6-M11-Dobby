//
//  CaptureProcessing.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// Mason 측 임시 촬영 경계. 실제 카메라와 목 구현이 같은 결과 형식을 반환한다.
@MainActor
protocol CaptureProviding {
    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset
    /// 목록에 반영하지 못한 새 촬영본만 정리한다. 외부 입력이나 이미 채택한 사진에는 호출하지 않는다.
    func discardUncommitted(_ asset: CapturedAsset) async throws
}

extension CaptureProviding {
    func discardUncommitted(_ asset: CapturedAsset) async throws { }
}

/// Provisional camera-facing contract, NOT Ichi's ML or Mugu's LiDAR implementation.
/// Adapters must return the input captureID and support caller cancellation.
/// RGB/depth synchronization and shared camera-session ownership remain unagreed.
@MainActor
protocol CaptureProcessing {
    func process(_ asset: CapturedAsset) async throws -> ProcessingResult
}
