import Foundation
import ImageIO
import SwiftData

nonisolated enum ProductDraftStep: String, Codable, Sendable, CaseIterable {
    case measurementResult, details, photoSelection, information

    var title: String {
        switch self {
        case .measurementResult: "실측 결과 단계"
        case .details: "상세 촬영 단계"
        // Keep the stored raw value readable; legacy drafts now resume capture.
        case .photoSelection: "상세 촬영 단계"
        case .information: "제품 정보 입력 단계"
        }
    }
}

nonisolated struct ProductCreationDraft: Codable, Sendable {
    var schemaVersion = 1
    let step: ProductDraftStep
    let measurementRecordID: UUID
    let photoState: ProductPhotoDraftSnapshot?
    let measurementInputData: Data?
    let savedAt: Date
    /// Optional so existing version-one drafts remain readable.
    var aiReviewNotes: [String]? = nil
    var usesProductAutofill: Bool? = nil
}

/// Captures remain in the camera's stable Application Support store until this
/// registration is completed or deleted. No live session or model is encoded.
nonisolated struct ProductPhotoDraftSnapshot: Codable, Sendable, Equatable {
    let sessionID: UUID
    let garmentID: UUID
    let measurementPhotoID: UUID
    let detailPhotos: [Photo]
    let selectedPhotoIDs: [UUID]
    /// Older saved drafts omit this session-level guide state.
    let hasAcknowledgedCaptureGuide: Bool?
    /// Optional for drafts written before gallery deletion was introduced.
    var deletedPhotoIDs: Set<UUID>? = nil

    struct Photo: Codable, Sendable, Equatable {
        let id: UUID
        /// Retained details may precede a measurement retake. Older drafts use
        /// the enclosing snapshot's session ID when this field is absent.
        let sessionID: UUID?
        let capturedAt: Date
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
        let contentType: String
        let orientationRaw: Int

        init(asset: CapturedAsset) throws {
            guard asset.purpose == .detail, case let .localFile(url, metadata) = asset.source,
                  url.isFileURL else { throw ProductDraftStore.DraftError.invalidPhotos }
            id = asset.id
            sessionID = asset.sessionID
            capturedAt = asset.capturedAt
            self.url = url
            pixelWidth = metadata.pixelWidth
            pixelHeight = metadata.pixelHeight
            contentType = metadata.contentType
            orientationRaw = metadata.orientation.rawValue
        }

        func asset(sessionID: UUID, garmentID: UUID) throws -> CapturedAsset {
            guard url.isFileURL, let orientation = CapturedAsset.Orientation(rawValue: orientationRaw),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetType(source) as String? == contentType,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == pixelWidth, pixelWidth > 0,
                  properties[kCGImagePropertyPixelHeight] as? Int == pixelHeight, pixelHeight > 0,
                  (properties[kCGImagePropertyOrientation] as? Int ?? 1) == orientationRaw else {
                throw ProductDraftStore.DraftError.missingPhoto
            }
            return CapturedAsset(id: id, sessionID: sessionID, garmentID: garmentID,
                purpose: .detail, capturedAt: capturedAt,
                source: .localFile(url, metadata: .init(pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight, contentType: contentType, orientation: orientation)))
        }
    }

    init(input: ProductPhotoInput, detailPhotos: [CapturedAsset], selectedPhotoIDs: [UUID],
         hasAcknowledgedCaptureGuide: Bool = false, deletedPhotoIDs: Set<UUID> = []) throws {
        guard Set(detailPhotos.map(\.id)).count == detailPhotos.count,
              detailPhotos.allSatisfy({ $0.garmentID == input.garmentID
                  && $0.id != input.measurement.id && $0.purpose == .detail }),
              Set(selectedPhotoIDs).count == selectedPhotoIDs.count,
              Set(selectedPhotoIDs).isSubset(of: Set(input.measurementPhotos.map(\.id) + detailPhotos.map(\.id))) else {
            throw ProductDraftStore.DraftError.invalidPhotos
        }
        sessionID = input.sessionID
        garmentID = input.garmentID
        measurementPhotoID = input.measurement.id
        self.detailPhotos = try detailPhotos.map(Photo.init)
        self.selectedPhotoIDs = selectedPhotoIDs
        self.hasAcknowledgedCaptureGuide = hasAcknowledgedCaptureGuide
        self.deletedPhotoIDs = deletedPhotoIDs
        _ = try restoredDetailPhotos(for: input)
    }

    func restoredDetailPhotos(for input: ProductPhotoInput) throws -> [CapturedAsset] {
        guard (deletedPhotoIDs ?? []).isDisjoint(with: selectedPhotoIDs),
              (deletedPhotoIDs ?? []).isDisjoint(with: detailPhotos.map(\.id)),
              sessionID == input.sessionID, garmentID == input.garmentID,
              measurementPhotoID == input.measurement.id,
              Set(detailPhotos.map(\.id)).count == detailPhotos.count,
              Set(detailPhotos.map { $0.url.standardizedFileURL }).count == detailPhotos.count,
              !detailPhotos.contains(where: { $0.id == measurementPhotoID }),
              Set(selectedPhotoIDs).count == selectedPhotoIDs.count,
              Set(selectedPhotoIDs).isSubset(of: Set(input.measurementPhotos.map(\.id) + detailPhotos.map(\.id))) else {
            throw ProductDraftStore.DraftError.invalidPhotos
        }
        return try detailPhotos.map { try $0.asset(sessionID: $0.sessionID ?? sessionID, garmentID: garmentID) }
    }
}

@MainActor
enum ProductDraftStore {
    static func save(garment: Garment, step: ProductDraftStep, measurementRecordID: UUID,
                     photoModel: ProductPhotoModel?, measurementInputData: Data?,
                     aiReviewNotes: [String]? = nil, usesProductAutofill: Bool? = nil,
                     in context: ModelContext,
                     persist: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard garment.modelContext === context, garment.informationCompletedAt == nil,
              garment.sourceMeasurementID == measurementRecordID else { throw DraftError.invalidProduct }
        let photoState = try photoModel?.makeDraftSnapshot()
        guard photoState.map({ $0.garmentID == garment.id
            && $0.measurementPhotoID == garment.measurementPhoto?.id
            && $0.sessionID == garment.measurementPhoto?.measurementSessionID }) ?? (step == .measurementResult) else {
            throw DraftError.invalidPhotos
        }
        let draft = ProductCreationDraft(step: step, measurementRecordID: measurementRecordID,
            photoState: photoState, measurementInputData: measurementInputData, savedAt: .now,
            aiReviewNotes: aiReviewNotes ?? garment.creationDraft?.aiReviewNotes,
            usesProductAutofill: usesProductAutofill ?? garment.creationDraft?.usesProductAutofill)
        let data = try JSONEncoder().encode(draft)
        let previousData = garment.creationDraftData
        let previousUpdatedAt = garment.updatedAt
        garment.creationDraftData = data
        garment.updatedAt = draft.savedAt
        do {
            try persist(context)
            photoModel?.didPersistDraft()
        }
        catch {
            // Keep the current text and measurements available for retry.
            garment.creationDraftData = previousData
            garment.updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// A draft's camera originals are only eligible for cleanup when their
    /// identities resolve to the exact store-owned path. Encoded URLs alone
    /// must never grant authority to delete another file.
    static func retainedCameraPhotoURLs(in draft: ProductCreationDraft?, garmentID: UUID) -> [URL] {
        guard let snapshot = draft?.photoState, snapshot.garmentID == garmentID else { return [] }
        let directories = [
            URL.applicationSupportDirectory.appending(path: "CameraPhotos", directoryHint: .isDirectory),
            ProductAppStorage.fixtureDirectory?.appending(path: "detail-captures", directoryHint: .isDirectory)
        ].compactMap { $0 }
        return snapshot.detailPhotos.compactMap { photo in
            guard photo.id != snapshot.measurementPhotoID, photo.url.isFileURL,
                  directories.contains(where: { directory in
                      directory.appending(path: (photo.sessionID ?? snapshot.sessionID).uuidString)
                          .appending(path: "\(photo.id.uuidString).jpg").standardizedFileURL
                          == photo.url.standardizedFileURL
                  }) else { return nil }
            return photo.url
        }
    }

    nonisolated enum DraftError: LocalizedError, Sendable {
        case invalidProduct, invalidPhotos, missingPhoto, operationInProgress
        var errorDescription: String? {
            switch self {
            case .invalidProduct: "이 작업을 저장할 수 없어요. 실측 결과를 다시 확인해 주세요."
            case .invalidPhotos: "촬영한 사진과 선택 내역을 확인하지 못했어요. 다시 시도해 주세요."
            case .missingPhoto: "저장된 촬영 사진을 불러오지 못했어요. 사진을 다시 확인해 주세요."
            case .operationInProgress: "사진 처리 중이에요. 처리가 끝나면 다시 나가기를 눌러 주세요."
            }
        }
    }
}
