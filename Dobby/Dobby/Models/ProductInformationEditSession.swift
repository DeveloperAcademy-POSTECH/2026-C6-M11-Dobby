// Created by mason on 10/30/26.

import Foundation
import Observation
import SwiftData

/// 보관함 편집은 별도 컨텍스트에서 진행하며 완료 버튼만 저장할 수 있습니다.
@MainActor @Observable
final class ProductInformationEditSession {
    let context: ModelContext
    let garment: Garment
    var measurementInput = GarmentMeasurementInputState()
    private let initialSnapshot: ProductInformationEditSnapshot

    init(garmentID: UUID, container: ModelContainer) throws {
        context = ModelContext(container)
        context.autosaveEnabled = false
        var request = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == garmentID })
        request.fetchLimit = 1
        guard let garment = try context.fetch(request).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.garment = garment
        initialSnapshot = ProductInformationEditSnapshot(
            garment: garment, measurementInput: GarmentMeasurementInputState()
        )
    }

    var hasChanges: Bool {
        initialSnapshot.hasChanges(in: garment, measurementInput: measurementInput)
    }

    func discard() {
        context.rollback()
        measurementInput = GarmentMeasurementInputState()
    }

    /// InfoInputView의 저장 성공 이후, 기존 상세·목록에서 관찰 중인 객체도 갱신합니다.
    func reflectSavedChanges(in original: Garment) {
        var input = GarmentMeasurementInputState()
        ProductInformationEditSnapshot(garment: garment, measurementInput: measurementInput)
            .restore(original, measurementInput: &input)
        original.informationCompletedAt = garment.informationCompletedAt
        original.creationDraftData = garment.creationDraftData
    }
}
