//
//  GarmentStore.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import Foundation
import SwiftData
import UIKit

/// 사진 파일과 레코드를 함께 다루는 자리.

enum GarmentStore {
    static let photosDirectory: URL = {
        let url = (ProductAppStorage.fixtureDirectory ?? URL.documentsDirectory)
            .appending(path: "photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(for photo: GarmentPhoto) -> URL {
        photosDirectory.appending(path: photo.fileName)
    }

    static func image(for photo: GarmentPhoto) -> UIImage? {
        UIImage(contentsOfFile: url(for: photo).path)
    }

    // MARK: 사진 추가
    @discardableResult
    static func addPhoto(_ image: UIImage, to garment: Garment, role: PhotoRole,
                         isMeasurementSource: Bool = false) throws -> GarmentPhoto {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw StoreError.encodingFailed
        }
        let fileName = "\(garment.id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
        try data.write(to: photosDirectory.appending(path: fileName), options: .atomic)

        let nextOrder = (garment.photos.map(\.order).max() ?? -1) + 1
        let photo = GarmentPhoto(fileName: fileName, role: role, order: nextOrder,
                                 isMeasurementSource: isMeasurementSource)
        photo.imageWidth = Int(image.size.width * image.scale)
        photo.imageHeight = Int(image.size.height * image.scale)
        garment.photos.append(photo)
        garment.updatedAt = .now
        return photo
    }

    /// 대표 사진은 한 벌에 하나뿐이어야 한다. 새로 지정하면 이전 것을 detail로 되돌린다.
    static func setThumbnail(_ photo: GarmentPhoto, in garment: Garment) {
        for existing in garment.photos where existing.role == .thumbnail {
            existing.role = .detail
        }
        photo.role = .thumbnail
        garment.updatedAt = .now
    }

    /// 사용자가 끌어서 바꾼 순서를 저장한다. 관계 배열 자체는 순서를 기억하지 않는다.
    static func reorder(_ ordered: [GarmentPhoto], in garment: Garment) {
        for (index, photo) in ordered.enumerated() {
            photo.order = index
        }
        garment.updatedAt = .now
    }

    // MARK: 삭제

    /// 레코드는 `.cascade`가 지우지만 파일은 지워주지 않으므로 여기서 먼저 치운다.
    static func delete(_ garment: Garment, in context: ModelContext) {
        for photo in garment.photos {
            try? FileManager.default.removeItem(at: url(for: photo))
        }
        context.delete(garment)
    }

    static func delete(_ photo: GarmentPhoto, in context: ModelContext) {
        try? FileManager.default.removeItem(at: url(for: photo))
        photo.garment?.updatedAt = .now
        context.delete(photo)
    }

    enum StoreError: LocalizedError {
        case encodingFailed
        var errorDescription: String? { "사진을 저장할 수 없습니다." }
    }
}

// MARK: - 파이프라인 결과 받기

extension GarmentStore {
    /// 실측이 끝난 직후 상품 한 벌을 만든다.
    ///
    /// 상품에 저장하는 `valueCm`만 소수 첫째 자리까지 버린다. `autoValueCm`은 모델이 처음 말한
    /// 정밀도를 보존해, 이후 사용자가 고쳤을 때 둘의 차이를 오차 기록으로 사용할 수 있게 한다.
    @discardableResult
    static func makeGarment(category: String, group: GarmentGroup,
                            measurements: [(key: String, label: String, cm: Double)],
                            landmarks: [(name: String, index: Int, x: Double, y: Double)],
                            measurementImage: UIImage,
                            garmentScore: Double?, pixelsPerCm: Double?,
                            in context: ModelContext) throws -> Garment {
        let garment = Garment(category: category, group: group)
        context.insert(garment)

        for (index, item) in measurements.enumerated() {
            garment.measurements.append(
                MeasuredValue(key: item.key, label: item.label, displayOrder: index,
                    valueCm: StoredMeasurementValue.centimeters(item.cm), autoValueCm: item.cm)
            )
        }

        let photo = try addPhoto(measurementImage, to: garment, role: .thumbnail,
                                 isMeasurementSource: true)
        photo.garmentScore = garmentScore
        photo.pixelsPerCm = pixelsPerCm
        for point in landmarks {
            photo.landmarks.append(
                LandmarkPoint(name: point.name, index: point.index, x: point.x, y: point.y)
            )
        }

        garment.syncFilterFields()
        return garment
    }
}
