//
//  ProductPhotoModel.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import Foundation
import Observation

/// 두 화면에서 공유하는 임시 MV Model. 실측/ML/LiDAR와 제품 전체 초안은 소유하지 않는다.
@MainActor
@Observable
final class ProductPhotoModel {
    let input: ProductPhotoInput
    private(set) var detailPhotos: [CapturedAsset] = []
    private(set) var selectedPhotoIDs: [UUID] = []
    private(set) var isCapturing = false
    @ObservationIgnored private let captureProvider: any CaptureProviding

    var photos: [CapturedAsset] { [input.measurement] + detailPhotos }

    // 임시 데모 규칙: 최소 한 장, 선택 순서 유지, 첫 선택이 대표 사진.
    // 실측샷 필수 여부·상한·대표 사진 별도 지정은 팀 합의 후 변경한다.
    var output: ProductPhotoOutput? {
        guard !isCapturing, let representativeID = selectedPhotoIDs.first else { return nil }
        return ProductPhotoOutput(
            sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: detailPhotos,
            selectedPhotos: selectedPhotoIDs.compactMap { id in photos.first { $0.id == id } },
            representativePhotoID: representativeID
        )
    }

    init(input: ProductPhotoInput, captureProvider: any CaptureProviding) throws {
        guard input.measurement.purpose == .measurement,
              input.measurement.sessionID == input.sessionID,
              input.measurement.garmentID == input.garmentID else {
            throw CameraFailure.mismatchedCapture
        }
        self.input = input
        self.captureProvider = captureProvider
    }

    func captureDetail() async throws {
        try Task.checkCancellation()
        guard !isCapturing else { throw CameraFailure.operationInProgress }
        isCapturing = true
        defer { isCapturing = false }
        let asset = try await captureProvider.capture(
            sessionID: input.sessionID, garmentID: input.garmentID
        )
        // 취소를 무시하는 provider의 늦은 응답도 초안에 반영하지 않는다.
        try Task.checkCancellation()
        guard asset.sessionID == input.sessionID, asset.garmentID == input.garmentID,
              asset.purpose == .detail, !photos.contains(where: { $0.id == asset.id }) else {
            throw CameraFailure.mismatchedCapture
        }
        detailPhotos.append(asset)
    }

    func toggleSelection(_ id: UUID) {
        guard photos.contains(where: { $0.id == id }) else { return }
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.removeAll { $0 == id }
        } else {
            selectedPhotoIDs.append(id)
        }
    }
}
