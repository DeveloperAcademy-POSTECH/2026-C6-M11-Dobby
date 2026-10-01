import ActivityKit
import Foundation

nonisolated struct ProductCopyAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var lastAttemptedField: String? = nil
        var message = "복사할 항목을 선택하세요"
    }
    let sessionID: UUID
    let channelName: String
    let values: ProductCopyValues
}
