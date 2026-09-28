import Foundation

/// User-entered test conditions. Optional in schema v1 so older records still open.
nonisolated struct MeasurementTestContext: Codable, Sendable, Equatable {
    var category: GarmentCategory = .top
    var specimenName = ""
    var deviceModel = ""
    var conditions = ""
}
