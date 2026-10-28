import Foundation
import SwiftData

@MainActor
enum ExportCompletionRecorder {
    static func record(productID: String, channel: ExportChannel, in modelContext: ModelContext) throws {
        guard let id = UUID(uuidString: productID) else { return }
        let descriptor = FetchDescriptor<Garment>(predicate: #Predicate<Garment> { $0.id == id })
        guard let garment = try modelContext.fetch(descriptor).first else { return }
        let record = ExportRecord(channel: channel, succeeded: true)
        record.garment = garment
        garment.exports.append(record)
        try modelContext.save()
    }
}
