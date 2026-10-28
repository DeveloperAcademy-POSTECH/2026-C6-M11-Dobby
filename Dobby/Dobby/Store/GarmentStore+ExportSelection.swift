import Foundation
import SwiftData

extension GarmentStore {
    /// 선택한 상품에만 기록한다. 데모나 삭제된 상품을 새로 만들지는 않는다.
    @MainActor
    static func recordSelectedExportChannel(_ channel: ExportChannel, productID: String,
                                           in context: ModelContext) throws {
        guard ExportChannel.availableCases.contains(channel),
              let id = UUID(uuidString: productID) else { return }
        var descriptor = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let garment = try context.fetch(descriptor).first,
              !garment.selectedExportChannels.contains(channel) else { return }

        let previous = garment.selectedExportChannelRawValues
        garment.selectedExportChannelRawValues = (previous ?? []) + [channel.rawValue]
        do {
            try context.save()
        } catch {
            garment.selectedExportChannelRawValues = previous
            throw error
        }
    }
}
