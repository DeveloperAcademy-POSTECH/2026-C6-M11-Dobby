import Foundation
import ImageIO
import SwiftData

/// 실측의 영구 사진을 상세 촬영의 입력으로 넘기고 선택 결과를 같은 상품에 저장한다.
@MainActor
enum ProductPhotoHandoff {
    static func makeInput(for garment: Garment, sessionID: UUID,
                          photosDirectory: URL? = nil) throws -> ProductPhotoInput {
        let photosDirectory = photosDirectory ?? GarmentStore.photosDirectory
        guard let photo = garment.measurementPhoto,
              photo.measurementSessionID == nil || photo.measurementSessionID == sessionID else {
            throw HandoffError.invalidInput
        }
        let url = photosDirectory.appending(path: photo.fileName)
        let metadata = try metadata(for: url)
        let asset = CapturedAsset(id: photo.id, sessionID: sessionID, garmentID: garment.id,
                                  purpose: .measurement, capturedAt: photo.capturedAt,
                                  source: .localFile(url, metadata: metadata))
        return ProductPhotoInput(sessionID: sessionID, garmentID: garment.id, measurement: asset)
    }

    /// 선택하지 않은 실측 원본도 점 보정을 위해 남긴다. 내보내기에는 productPhotos만 사용한다.
    /// 파일 복사는 UI 스레드 밖에서 하고, 성공한 파일만 SwiftData 관계에 넣는다.
    static func apply(_ output: ProductPhotoOutput, to garment: Garment, in context: ModelContext,
                      input: ProductPhotoInput,
                      photosDirectory: URL? = nil,
                      includesAllCapturedPhotos: Bool = false,
                      persist: @MainActor (ModelContext) throws -> Void = { try $0.save() }) async throws {
        let photosDirectory = photosDirectory ?? GarmentStore.photosDirectory
        try Task.checkCancellation()
        try validate(output, input: input, garment: garment, photosDirectory: photosDirectory)
        if includesAllCapturedPhotos {
            let remaining = (input.measurementPhotos + output.detailPhotos).filter { !output.deletedPhotoIDs.contains($0.id) }
            guard output.selectedPhotos == remaining,
                  output.representativePhotoID == remaining.first?.id else {
                throw HandoffError.invalidOutput
            }
        }
        let existingIDs = Set(garment.photos.map(\.id))
        let newAssets = output.selectedPhotos.filter { !existingIDs.contains($0.id) }
        let plans = newAssets.map { PhotoCopyPlan(asset: $0, garmentID: garment.id, directory: photosDirectory) }
        let copied = try await Task.detached(priority: .userInitiated) {
            try copyOriginals(plans)
        }.value

        var added: [GarmentPhoto] = []
        let previousPhotos = garment.photos
        let previousState = previousPhotos.map { PhotoState(photo: $0) }
        let previousUpdatedAt = garment.updatedAt
        let previousAppliedAt = garment.capturePhotosAppliedAt
        do {
            try Task.checkCancellation()
            // 같은 초안에서 중복 완료가 겹쳐 원본이나 선택 순서를 덮어쓰지 않게 한다.
            guard Set(previousPhotos.map(\.id)) == existingIDs else { throw HandoffError.changedDraft }
            for plan in copied {
                let photo = GarmentPhoto(fileName: plan.fileName, role: .detail, order: 0)
                photo.id = plan.asset.id
                photo.capturedAt = plan.asset.capturedAt
                if case let .localFile(_, metadata) = plan.asset.source {
                    photo.imageWidth = metadata.pixelWidth
                    photo.imageHeight = metadata.pixelHeight
                }
                context.insert(photo)
                added.append(photo)
                garment.photos.append(photo)
            }
            let preservesEdits = includesAllCapturedPhotos && (previousAppliedAt != nil
                || garment.informationCompletedAt != nil || garment.creationDraft?.step == .information)
            if preservesEdits {
                // 입력 화면의 순서·제외·대표 사진은 유지하고 새 촬영만 끝에 추가한다.
                for photo in added { photo.isSelectedForProduct = true }
                GarmentStore.reorder(previousPhotos.sorted { $0.order < $1.order } + added, in: garment)
            } else {
                let selectedIDs = output.selectedPhotos.map(\.id)
                for photo in garment.photos {
                    photo.isSelectedForProduct = selectedIDs.contains(photo.id)
                    photo.role = photo.id == output.representativePhotoID ? .thumbnail : .detail
                }
                let selected = selectedIDs.compactMap { id in garment.photos.first { $0.id == id } }
                let retained = garment.orderedPhotos.filter { !selectedIDs.contains($0.id) }
                GarmentStore.reorder(selected + retained, in: garment)
            }
            // 입력 화면에서 이미 정한 순서는 유지하되, 촬영 갤러리에서 삭제한 사진은 되살리지 않는다.
            for photo in garment.photos where output.deletedPhotoIDs.contains(photo.id) {
                photo.isSelectedForProduct = false
                photo.role = .detail
            }
            if !garment.productPhotos.contains(where: { $0.role == .thumbnail }) {
                garment.productPhotos.first?.role = .thumbnail
            }
            if includesAllCapturedPhotos { garment.capturePhotosAppliedAt = previousAppliedAt ?? .now }
            try persist(context)
        } catch {
            garment.photos = previousPhotos
            for state in previousState { state.restore() }
            garment.updatedAt = previousUpdatedAt
            garment.capturePhotosAppliedAt = previousAppliedAt
            for photo in added { context.delete(photo) }
            // 촬영 원본과 이전부터 존재한 상품 파일은 삭제하지 않는다.
            await Task.detached { removeCopiedFiles(copied) }.value
            throw error
        }
    }

    private static func validate(_ output: ProductPhotoOutput, input: ProductPhotoInput,
                                 garment: Garment, photosDirectory: URL) throws {
        guard input.garmentID == garment.id, output.garmentID == garment.id,
              output.sessionID == input.sessionID,
              input.measurement.sessionID == input.sessionID,
              input.measurement.garmentID == garment.id,
              input.measurement.purpose == .measurement,
              let measurement = garment.measurementPhoto,
              input.measurement.id == measurement.id,
              measurement.measurementSessionID == nil || measurement.measurementSessionID == input.sessionID,
              case let .localFile(measurementURL, _) = input.measurement.source,
              measurementURL.standardizedFileURL == photosDirectory.appending(path: measurement.fileName).standardizedFileURL,
              output.deletedPhotoIDs.isDisjoint(with: output.selectedPhotos.map(\.id)),
              output.deletedPhotoIDs.isDisjoint(with: output.detailPhotos.map(\.id)),
              !output.selectedPhotos.isEmpty,
              Set(output.selectedPhotos.map(\.id)).count == output.selectedPhotos.count,
              Set(output.detailPhotos.map(\.id)).count == output.detailPhotos.count,
              output.selectedPhotos.contains(where: { $0.id == output.representativePhotoID }) else {
            throw HandoffError.invalidOutput
        }
        for detail in output.detailPhotos {
            guard detail.garmentID == garment.id,
                  detail.purpose == .detail, detail.id != measurement.id,
                  case let .localFile(url, _) = detail.source, url.isFileURL else {
                throw HandoffError.invalidOutput
            }
        }
        for selected in output.selectedPhotos {
            guard input.measurementPhotos.contains(selected) || output.detailPhotos.contains(selected) else {
                throw HandoffError.invalidOutput
            }
        }
        if let visualization = input.measurementVisualization {
            guard visualization.purpose == .measurementVisualization,
                  visualization.sessionID == input.sessionID, visualization.garmentID == garment.id,
                  visualization.id != measurement.id,
                  !output.detailPhotos.contains(where: { $0.id == visualization.id }),
                  let stored = garment.photos.first(where: { $0.id == visualization.id }),
                  !stored.isMeasurementSource,
                  case let .localFile(url, _) = visualization.source,
                  url.standardizedFileURL == photosDirectory.appending(path: stored.fileName).standardizedFileURL else {
                throw HandoffError.invalidOutput
            }
        }
    }

    nonisolated static func metadata(for url: URL) throws -> CapturedAsset.ImageMetadata {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == "public.jpeg" || type == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              let orientation = CapturedAsset.Orientation(rawValue: properties[kCGImagePropertyOrientation] as? Int ?? 1) else {
            throw HandoffError.unreadablePhoto
        }
        return .init(pixelWidth: width, pixelHeight: height, contentType: type, orientation: orientation)
    }

    nonisolated private static func copyOriginals(_ plans: [PhotoCopyPlan]) throws -> [PhotoCopyPlan] {
        var written: [PhotoCopyPlan] = []
        do {
            for plan in plans {
                try Task.checkCancellation()
                guard case let .localFile(source, expectedMetadata) = plan.asset.source else {
                    throw HandoffError.unreadablePhoto
                }
                let actualMetadata = try metadata(for: source)
                guard actualMetadata.pixelWidth == expectedMetadata.pixelWidth,
                      actualMetadata.pixelHeight == expectedMetadata.pixelHeight,
                      actualMetadata.contentType == expectedMetadata.contentType,
                      actualMetadata.orientation.rawValue == expectedMetadata.orientation.rawValue else {
                    throw HandoffError.unreadablePhoto
                }
                try FileManager.default.createDirectory(at: plan.directory, withIntermediateDirectories: true)
                guard !FileManager.default.fileExists(atPath: plan.destination.path) else {
                    throw HandoffError.fileAlreadyExists
                }
                let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
                // Foundation은 atomic과 withoutOverwriting의 조합을 지원하지 않는다.
                // 같은 폴더의 새 임시 파일을 완성한 뒤 이동하며 기존 파일은 덮어쓰지 않는다.
                let staging = plan.directory.appending(path: ".dobby-photo-\(UUID().uuidString).tmp")
                do {
                    try bytes.write(to: staging, options: .atomic)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: staging, to: plan.destination)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                written.append(plan)
            }
            try Task.checkCancellation()
            return written
        } catch {
            removeCopiedFiles(written)
            throw error
        }
    }

    nonisolated private static func removeCopiedFiles(_ plans: [PhotoCopyPlan]) {
        for plan in plans { try? FileManager.default.removeItem(at: plan.destination) }
    }

    enum HandoffError: LocalizedError {
        case invalidInput, invalidOutput, unreadablePhoto, fileAlreadyExists, changedDraft
        var errorDescription: String? {
            switch self {
            case .invalidInput: "실측 사진을 불러올 수 없어요. 다시 촬영해 주세요."
            case .invalidOutput, .changedDraft: "이 상품의 사진 선택 결과를 확인하지 못했어요. 다시 선택해 주세요."
            case .unreadablePhoto: "사진을 읽을 수 없어요. 다른 사진을 선택하거나 다시 촬영해 주세요."
            case .fileAlreadyExists: "사진 저장 경로가 사용 중이에요. 다시 시도해 주세요."
            }
        }
    }

    private struct PhotoState {
        let photo: GarmentPhoto
        let role: PhotoRole
        let order: Int
        let selected: Bool?
        init(photo: GarmentPhoto) {
            self.photo = photo; role = photo.role; order = photo.order; selected = photo.isSelectedForProduct
        }
        func restore() { photo.role = role; photo.order = order; photo.isSelectedForProduct = selected }
    }

    nonisolated private struct PhotoCopyPlan: Sendable {
        let asset: CapturedAsset
        let directory: URL
        let fileName: String
        var destination: URL { directory.appending(path: fileName) }
        init(asset: CapturedAsset, garmentID: UUID, directory: URL) {
            self.asset = asset; self.directory = directory
            let suffix: String
            if case let .localFile(_, metadata) = asset.source, metadata.contentType == "public.png" { suffix = "png" }
            else { suffix = "jpg" }
            fileName = "\(garmentID.uuidString)-\(asset.id.uuidString).\(suffix)"
        }
    }
}
