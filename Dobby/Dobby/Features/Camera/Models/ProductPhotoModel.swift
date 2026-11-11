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
    static let maximumSelectionCount = ProductPhotoLimit.maximumCount
    enum SelectionResult: Equatable { case updated, limitReached, ignored }

    private(set) var input: ProductPhotoInput
    // 이전 화면의 확정 결과를 열람용으로 보관한다. 측정 계산·수정은 소유하지 않는다.
    private(set) var measurementRecord: SavedMeasurement?
    private(set) var detailPhotos: [CapturedAsset] = []
    private(set) var selectedPhotoIDs: [UUID] = []
    private(set) var deletedPhotoIDs: Set<UUID> = []
    private(set) var isCapturing = false
    private(set) var isDeleting = false
    // 같은 사진 초안으로 재진입할 때 안내를 반복하지 않는다. 앱 전체 영구 설정은 아니다.
    private(set) var hasAcknowledgedCaptureGuide = false
    private var isDiscardingDetails = false
    @ObservationIgnored private var deletionTask: Task<Void, Error>?
    @ObservationIgnored private var persistedDetailPhotoIDs: Set<UUID> = []
    @ObservationIgnored private var deferredDetailDeletions: [CapturedAsset] = []
    @ObservationIgnored private var committedCleanupTask: Task<Void, Never>?
    @ObservationIgnored private let captureProvider: any CaptureProviding
    @ObservationIgnored private var discardRevision = 0

    var photos: [CapturedAsset] { ([input.measurement] + detailPhotos).filter { !deletedPhotoIDs.contains($0.id) } }
    /// 같은 촬영의 원본·실측값 표시본을 나란히 두고 상세 사진은 촬영 순서로 이어 붙인다.
    var selectablePhotos: [CapturedAsset] {
        (input.measurementPhotos + detailPhotos).filter { !deletedPhotoIDs.contains($0.id) }
    }

    /// 선택 화면을 거치지 않는 전체 촬영 결과. 기존 선택 상태와 10장 제한을 적용하지 않는다.
    /// 저장소에서 이미 편집한 상품 사진의 순서·제외 여부는 전달받는 쪽에서 보존한다.
    var allPhotosOutput: ProductPhotoOutput? {
        guard !isCapturing, !isDeleting, !isDiscardingDetails,
              let first = selectablePhotos.first else { return nil }
        return ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: detailPhotos, selectedPhotos: selectablePhotos,
            representativePhotoID: first.id, deletedPhotoIDs: deletedPhotoIDs)
    }

    /// 하단 표시 전용. 상단 캐러셀이 사용하는 촬영 순서는 바꾸지 않는다.
    var selectionOrderedPhotos: [CapturedAsset] {
        let selected = Set(selectedPhotoIDs)
        let assets = Dictionary(uniqueKeysWithValues: selectablePhotos.map { ($0.id, $0) })
        return selectedPhotoIDs.compactMap { assets[$0] } + selectablePhotos.filter { !selected.contains($0.id) }
    }

    // 최소 한 장, 선택 순서 유지, 첫 선택이 대표 사진이다.
    var output: ProductPhotoOutput? {
        guard !isCapturing, !isDeleting, !isDiscardingDetails,
              selectedPhotoIDs.count <= Self.maximumSelectionCount,
              let representativeID = selectedPhotoIDs.first else { return nil }
        return ProductPhotoOutput(
            sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: detailPhotos,
            selectedPhotos: selectedPhotoIDs.compactMap { id in selectablePhotos.first { $0.id == id } },
            representativePhotoID: representativeID, deletedPhotoIDs: deletedPhotoIDs
        )
    }

    init(input: ProductPhotoInput, captureProvider: any CaptureProviding,
         initialDetailPhotos: [CapturedAsset] = [],
         initialSelectedPhotoIDs: [UUID] = [], measurementRecord: SavedMeasurement? = nil,
         initialDeletedPhotoIDs: Set<UUID> = []) throws {
        guard input.measurement.purpose == .measurement,
              input.measurement.sessionID == input.sessionID,
              input.measurement.garmentID == input.garmentID,
              Set(initialDetailPhotos.map(\.id)).count == initialDetailPhotos.count,
              Set(initialDetailPhotos.compactMap { asset -> URL? in
                  if case let .localFile(url, _) = asset.source { return url.standardizedFileURL }
                  return nil
              }).count == initialDetailPhotos.count,
              initialDetailPhotos.allSatisfy({ asset in
                  guard asset.id != input.measurement.id, asset.purpose == .detail,
                        asset.garmentID == input.garmentID,
                        case let .localFile(url, metadata) = asset.source else { return false }
                  return url.isFileURL && metadata.pixelWidth > 0 && metadata.pixelHeight > 0
              }),
              initialDeletedPhotoIDs.isDisjoint(with: initialSelectedPhotoIDs),
              initialDeletedPhotoIDs.isDisjoint(with: initialDetailPhotos.map(\.id)),
              Set(initialSelectedPhotoIDs).count == initialSelectedPhotoIDs.count,
              Set(initialSelectedPhotoIDs).isSubset(of: Set(input.measurementPhotos.map(\.id) + initialDetailPhotos.map(\.id))) else {
            throw CameraFailure.mismatchedCapture
        }
        self.input = input
        try Self.validateVisualization(input.measurementVisualization, input: input, details: initialDetailPhotos)
        if let measurementRecord {
            guard measurementRecord.snapshot.frame.sessionID == input.sessionID else {
                throw CameraFailure.mismatchedCapture
            }
        }
        self.measurementRecord = measurementRecord
        self.captureProvider = captureProvider
        detailPhotos = initialDetailPhotos
        persistedDetailPhotoIDs = Set(initialDetailPhotos.map(\.id))
        selectedPhotoIDs = initialSelectedPhotoIDs
        deletedPhotoIDs = initialDeletedPhotoIDs
    }

    func makeDraftSnapshot() throws -> ProductPhotoDraftSnapshot {
        guard !isCapturing, !isDeleting, !isDiscardingDetails else {
            throw ProductDraftStore.DraftError.operationInProgress
        }
        return try ProductPhotoDraftSnapshot(input: input, detailPhotos: detailPhotos,
            selectedPhotoIDs: selectedPhotoIDs, hasAcknowledgedCaptureGuide: hasAcknowledgedCaptureGuide,
            deletedPhotoIDs: deletedPhotoIDs)
    }

    /// A retake changes the measurement session, not the ownership or capture
    /// provenance of detail photos. Publish this candidate only after saving.
    func replacingMeasurement(with input: ProductPhotoInput, record: SavedMeasurement) throws -> ProductPhotoModel {
        guard !isCapturing, !isDeleting, !isDiscardingDetails,
              input.garmentID == self.input.garmentID,
              input.measurement.id == self.input.measurement.id else {
            throw CameraFailure.mismatchedCapture
        }
        let selected = selectedPhotoIDs.compactMap { id in
            id == self.input.measurementVisualization?.id ? input.measurementVisualization?.id : id
        }
        let candidate = try ProductPhotoModel(input: input, captureProvider: captureProvider,
            initialDetailPhotos: detailPhotos, initialSelectedPhotoIDs: selected, measurementRecord: record)
        // 새로 실측한 사진은 다시 제공하되 이전 상세 컷 삭제 내역은 유지한다.
        candidate.deletedPhotoIDs = deletedPhotoIDs.subtracting(self.input.measurementPhotos.map(\.id))
        candidate.hasAcknowledgedCaptureGuide = hasAcknowledgedCaptureGuide
        candidate.persistedDetailPhotoIDs = persistedDetailPhotoIDs
        candidate.deferredDetailDeletions = deferredDetailDeletions
        candidate.committedCleanupTask = committedCleanupTask
        return candidate
    }

    /// Point corrections keep the same frozen capture while replacing the
    /// confirmed record that the photo-flow measurement preview displays.
    func updateMeasurementRecord(_ record: SavedMeasurement, visualization: CapturedAsset? = nil) throws {
        guard record.snapshot.frame.sessionID == input.sessionID,
              measurementRecord.map({ $0.snapshot.frame.frameID == record.snapshot.frame.frameID }) ?? true else {
            throw CameraFailure.mismatchedCapture
        }
        try Self.validateVisualization(visualization, input: input, details: detailPhotos)
        if let old = input.measurementVisualization, old.id != visualization?.id {
            selectedPhotoIDs = selectedPhotoIDs.compactMap { $0 == old.id ? visualization?.id : $0 }
            if deletedPhotoIDs.contains(old.id), let visualization {
                deletedPhotoIDs.insert(visualization.id)
            }
        }
        input.measurementVisualization = visualization
        measurementRecord = record
    }

    private static func validateVisualization(_ asset: CapturedAsset?, input: ProductPhotoInput,
                                               details: [CapturedAsset]) throws {
        guard let asset else { return }
        guard asset.purpose == .measurementVisualization, asset.id != input.measurement.id,
              asset.sessionID == input.sessionID, asset.garmentID == input.garmentID,
              !details.contains(where: { $0.id == asset.id }),
              case let .localFile(url, metadata) = asset.source, url.isFileURL,
              metadata.pixelWidth > 0, metadata.pixelHeight > 0 else { throw CameraFailure.mismatchedCapture }
    }

    /// Called only after the new payload is durable. A previous saved draft
    /// must remain readable while the user edits it or retries a failed save.
    func didPersistDraft() {
        persistedDetailPhotoIDs = Set(detailPhotos.map(\.id))
        let retired = deferredDetailDeletions
        guard !retired.isEmpty else { return }
        let previousCleanup = committedCleanupTask
        committedCleanupTask = Task { [weak self, captureProvider] in
            await previousCleanup?.value
            for photo in retired {
                if self?.isProductStoredPhoto(photo) == true {
                    self?.deferredDetailDeletions.removeAll { $0.id == photo.id }
                    continue
                }
                do {
                    try await captureProvider.discardUncommitted(photo)
                    self?.deferredDetailDeletions.removeAll { $0.id == photo.id }
                } catch {
                    // Retry through the next successful save or final cleanup.
                }
            }
        }
    }

    func acknowledgeCaptureGuide() {
        hasAcknowledgedCaptureGuide = true
    }

    /// Product-information edits use stored photos, while camera selection and
    /// draft restoration use this model. Keep their exact selection order equal.
    @discardableResult
    func synchronizeSelectedProductPhotos(_ orderedIDs: [UUID]) -> Bool {
        guard !isCapturing, !isDeleting, !isDiscardingDetails,
              orderedIDs.count <= Self.maximumSelectionCount,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs).isSubset(of: Set(selectablePhotos.map(\.id))) else { return false }
        selectedPhotoIDs = orderedIDs
        return true
    }

    /// Product-input additions already live in the product store. Register
    /// their IDs for AI selection and draft restoration without camera ownership.
    func synchronizeStoredProductPhotos(_ photos: [GarmentPhoto]) throws {
        guard !isCapturing, !isDeleting, !isDiscardingDetails else { throw CameraFailure.operationInProgress }
        let known = Set(input.measurementPhotos.map(\.id) + detailPhotos.map(\.id))
        var added: [CapturedAsset] = []
        for photo in photos where !known.contains(photo.id) && !deletedPhotoIDs.contains(photo.id) {
            let url = GarmentStore.url(for: photo)
            let metadata = try ProductPhotoHandoff.metadata(for: url)
            added.append(CapturedAsset(id: photo.id, sessionID: input.sessionID, garmentID: input.garmentID,
                purpose: .detail, capturedAt: photo.capturedAt, source: .localFile(url, metadata: metadata)))
        }
        detailPhotos.append(contentsOf: added)
        persistedDetailPhotoIDs.formUnion(added.map(\.id))
    }

    private func isProductStoredPhoto(_ photo: CapturedAsset) -> Bool {
        guard case let .localFile(url, _) = photo.source else { return false }
        return url.deletingLastPathComponent().standardizedFileURL == GarmentStore.photosDirectory.standardizedFileURL
    }

    func captureDetail() async throws {
        try Task.checkCancellation()
        guard !isCapturing, !isDeleting, !isDiscardingDetails else { throw CameraFailure.operationInProgress }
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
                  asset.purpose == .detail, !deletedPhotoIDs.contains(asset.id),
                  !input.measurementPhotos.contains(where: { $0.id == asset.id }),
                  !detailPhotos.contains(where: { $0.id == asset.id }) else {
                throw CameraFailure.mismatchedCapture
            }
            detailPhotos.append(asset)
        } catch {
            // 이미 목록에 있는 ID는 중복 응답이므로 기존 원본을 지우지 않는다.
            if !deletedPhotoIDs.contains(asset.id),
               !(input.measurementPhotos + detailPhotos).contains(where: { $0.id == asset.id }) {
                try await captureProvider.discardUncommitted(asset)
            }
            throw error
        }
    }

    /// 실측 수치·보정용 원자료는 보존하고 갤러리 및 상품 전달에서 제외한다.
    func deletePhoto(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !isCapturing, !isDeleting, !isDiscardingDetails else { throw CameraFailure.operationInProgress }
        guard let photo = selectablePhotos.first(where: { $0.id == id }) else { throw CameraFailure.missingCapture }
        if photo.purpose == .detail {
            try await deleteDetail(id)
        } else {
            deletedPhotoIDs.insert(id)
            selectedPhotoIDs.removeAll { $0 == id }
        }
    }

    /// 새 촬영본은 저장소 삭제 후 목록을 갱신한다. 저장된 초안의 원본은 다음
    /// 저장 성공까지 보존하고 목록에서만 제외한다. 실측 입력은 삭제할 수 없다.
    func deleteDetail(_ id: UUID) async throws {
        try Task.checkCancellation()
        guard !isCapturing, !isDeleting, !isDiscardingDetails else { throw CameraFailure.operationInProgress }
        guard let photo = detailPhotos.first(where: { $0.id == id }),
              photo.purpose == .detail, id != input.measurement.id else { throw CameraFailure.missingCapture }
        isDeleting = true
        defer { isDeleting = false; deletionTask = nil }
        // 화면 이탈로 호출 Task가 취소되어도 파일 삭제와 목록 반영을 함께 마친다.
        let task = Task {
            if persistedDetailPhotoIDs.contains(photo.id) {
                if !deferredDetailDeletions.contains(where: { $0.id == photo.id }) {
                    deferredDetailDeletions.append(photo)
                }
            } else {
                try await captureProvider.discardUncommitted(photo)
            }
            deletedPhotoIDs.insert(id)
            detailPhotos.removeAll { $0.id == id }
            selectedPhotoIDs.removeAll { $0 == id }
        }
        deletionTask = task
        try await task.value
    }

    @discardableResult
    func toggleSelection(_ id: UUID) -> SelectionResult {
        guard !isDeleting, !isDiscardingDetails, selectablePhotos.contains(where: { $0.id == id }) else { return .ignored }
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.removeAll { $0 == id }
        } else {
            guard selectedPhotoIDs.count < Self.maximumSelectionCount else { return .limitReached }
            selectedPhotoIDs.append(id)
        }
        return .updated
    }

    func moveSelection(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !isCapturing, !isDeleting, !isDiscardingDetails,
              destination >= 0, destination <= selectedPhotoIDs.count,
              offsets.allSatisfy({ selectedPhotoIDs.indices.contains($0) }) else { return }
        let moved = offsets.sorted().map { selectedPhotoIDs[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted().reversed() { selectedPhotoIDs.remove(at: index) }
        selectedPhotoIDs.insert(contentsOf: moved, at: insertion)
    }

    /// 완료 또는 취소 시 이 모델이 촬영한 임시 상세 원본만 정리한다.
    /// 실측 입력과 영구 저장소로 복사한 상품 사진은 이 provider가 소유하지 않는다.
    func discardUncommittedDetails() async throws {
        guard !isDiscardingDetails else { throw CameraFailure.operationInProgress }
        isDiscardingDetails = true
        defer { isDiscardingDetails = false }
        discardRevision += 1
        // 단건 삭제가 끝난 목록을 정리하고, 삭제 실패한 사진도 다시 정리한다.
        if let deletionTask { _ = try? await deletionTask.value }
        await committedCleanupTask?.value
        let discarded = detailPhotos + deferredDetailDeletions
        detailPhotos = []
        deferredDetailDeletions = []
        persistedDetailPhotoIDs = []
        selectedPhotoIDs.removeAll { id in discarded.contains { $0.id == id } }
        var firstError: (any Error)?
        for photo in discarded {
            // Product files are cleaned by the product store, never its camera provider.
            if isProductStoredPhoto(photo) { continue }
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
