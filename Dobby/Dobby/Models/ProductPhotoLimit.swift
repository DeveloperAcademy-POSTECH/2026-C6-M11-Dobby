import Foundation

/// Registered product pictures and saved camera originals have different bounds.
/// Never delete a captured original merely to satisfy the registration limit.
nonisolated enum ProductPhotoLimit {
    static let maximumCount = 10
    static func remaining(after count: Int) -> Int { max(0, maximumCount - max(0, count)) }
    static func canRegister(count: Int) -> Bool { (1...maximumCount).contains(count) }

    /// Preserve existing selections (including legacy overflow for user repair)
    /// and fill only the remaining slots with newly captured pictures.
    static func registrationIDs(existing: [UUID], incoming: [UUID]) -> [UUID] {
        var seen = Set(existing)
        let additions = incoming.filter { seen.insert($0).inserted }
        return existing + additions.prefix(remaining(after: existing.count))
    }

    enum ValidationError: LocalizedError {
        case tooManyPhotos
        var errorDescription: String? { "제품 사진은 최대 10장까지 등록할 수 있어요. 사진을 빼고 다시 완료해 주세요." }
    }
}
