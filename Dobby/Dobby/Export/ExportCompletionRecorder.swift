import Foundation
import SwiftData

@MainActor
enum ExportCompletionRecorder {
    static func record(productID: String, channel: ExportChannel, in modelContext: ModelContext,
                       save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        guard ExportChannel.availableCases.contains(channel),
              let id = UUID(uuidString: productID) else { return }
        var descriptor = FetchDescriptor<Garment>(predicate: #Predicate<Garment> { $0.id == id })
        descriptor.fetchLimit = 1
        guard let garment = try modelContext.fetch(descriptor).first else { return }
        let previousExports = garment.exports
        let record = ExportRecord(channel: channel, succeeded: true)
        modelContext.insert(record)
        garment.exports.append(record)
        do {
            try save(modelContext)
        } catch {
            garment.exports = previousExports
            modelContext.delete(record)
            throw error
        }
    }
}
