import Foundation

nonisolated enum ProductTextLimit {
    static let name = 60
    static let detail = 2_200

    static func allowsChange(from currentText: String, to newText: String, maximumLength: Int) -> Bool {
        newText.count <= maximumLength || newText.count < currentText.count
    }

    static func truncated(_ text: String, maximumLength: Int) -> String {
        String(text.prefix(maximumLength))
    }
}
