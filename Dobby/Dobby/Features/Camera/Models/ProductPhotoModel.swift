//
//  ProductPhotoModel.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import Foundation
import Observation

/// 상세 촬영과 사진 선택에서 공유한다. 실측/ML/LiDAR와 제품 전체 초안은 소유하지 않는다.
@MainActor
@Observable
final class ProductPhotoModel {
    let input: ProductPhotoInput
    private(set) var detailPhotos: [CapturedAsset] = []
    private(set) var selectedPhotoIDs: [UUID] = []
    private(set) var isCapturing = false
    @ObservationIgnored private let captureProvider: any CaptureProviding
    @ObservationIgnored private var discardRevision = 0

    var photos: [CapturedAsset] { [input.measurement] + detailPhotos }

    // 최소 한 장, 선택 순서 유지, 첫 선택이 대표 사진이다.
    var output: ProductPhotoOutput? {
        guard !isCapturing, let representativeID = selectedPhotoIDs.first else { return nil }
        return ProductPhotoOutput(
            sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: detailPhotos,
            selectedPhotos: selectedPhotoIDs.compactMap { id in photos.first { $0.id == id } },
            representativePhotoID: representativeID
        )
    }

    init(input: ProductPhotoInput, captureProvider: any CaptureProviding,
         initialSelectedPhotoIDs: [UUID] = []) throws {
        guard input.measurement.purpose == .measurement,
              input.measurement.sessionID == input.sessionID,
              input.measurement.garmentID == input.garmentID,
              Set(initialSelectedPhotoIDs).count == initialSelectedPhotoIDs.count,
              initialSelectedPhotoIDs.allSatisfy({ $0 == input.measurement.id }) else {
            throw CameraFailure.mismatchedCapture
        }
        self.input = input
        self.captureProvider = captureProvider
        selectedPhotoIDs = initialSelectedPhotoIDs
    }

    func captureDetail() async throws {
        try Task.checkCancellation()
        guard !isCapturing else { throw CameraFailure.operationInProgress }
        isCapturing = true
        defer { isCapturing = false }
        let revision = discardRevision
        let asset = try await captureProvider.capture(
            sessionID: input.sessionID, garmentID: input.garmentID
        )
        // 취소를 무시하는 provider의 늦은 응답도 초안에 반영하지 않는다.
        do {
            try Task.checkCancellation()
            guard revision == discardRevision else { throw CancellationError() }
            guard asset.sessionID == input.sessionID, asset.garmentID == input.garmentID,
                  asset.purpose == .detail, !photos.contains(where: { $0.id == asset.id }) else {
                throw CameraFailure.mismatchedCapture
            }
            detailPhotos.append(asset)
        } catch {
            // 이미 목록에 있는 ID는 중복 응답이므로 기존 원본을 지우지 않는다.
            if !photos.contains(where: { $0.id == asset.id }) { try await captureProvider.discardUncommitted(asset) }
            throw error
        }
    }

    func toggleSelection(_ id: UUID) {
        guard photos.contains(where: { $0.id == id }) else { return }
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.removeAll { $0 == id }
        } else {
            selectedPhotoIDs.append(id)
        }
    }

    func moveSelection(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !isCapturing, destination >= 0, destination <= selectedPhotoIDs.count,
              offsets.allSatisfy({ selectedPhotoIDs.indices.contains($0) }) else { return }
        let moved = offsets.sorted().map { selectedPhotoIDs[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted().reversed() { selectedPhotoIDs.remove(at: index) }
        selectedPhotoIDs.insert(contentsOf: moved, at: insertion)
    }

    /// 완료 또는 취소 시 이 모델이 촬영한 임시 상세 원본만 정리한다.
    /// 실측 입력과 영구 저장소로 복사한 상품 사진은 이 provider가 소유하지 않는다.
    func discardUncommittedDetails() async throws {
        discardRevision += 1
        let discarded = detailPhotos
        detailPhotos = []
        selectedPhotoIDs.removeAll { id in discarded.contains { $0.id == id } }
        var firstError: (any Error)?
        for photo in discarded {
            do { try await captureProvider.discardUncommitted(photo) }
            catch {
                // 정리 실패한 파일은 다음 정리 요청에서 다시 시도할 수 있게 보존한다.
                detailPhotos.append(photo)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}
