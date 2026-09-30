import Foundation
import OSLog
import UIKit

struct ForegroundCopyRelayResult {
    let copied: Bool
    let field: ProductCopyField?
    let destination: URL?
}

@MainActor
enum ForegroundCopyRelay {
    private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "ForegroundCopyRelay")
    private static let testValue = "FF-A-56000"

    static func canHandle(_ url: URL) -> Bool {
        url.scheme == "dobby-copy" && (url.host == "copy" || url.host == "copy-test")
    }

    static func handle(_ url: URL) -> ForegroundCopyRelayResult {
        if url.host == "copy-test" {
            return copy(value: testValue, field: nil, destination: nil)
        }

        guard url.host == "copy",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawField = components.queryItems?.first(where: { $0.name == "field" })?.value,
              let field = ProductCopyField(rawValue: rawField),
              let session = ProductCopyStore.load() else {
            logger.error("Foreground relay rejected an invalid URL or missing session. url=\(url.absoluteString, privacy: .public)")
            return .init(copied: false, field: nil, destination: nil)
        }

        return copy(
            value: session.payload.value(for: field),
            field: field,
            destination: session.channel.destination
        )
    }

    private static func copy(
        value: String,
        field: ProductCopyField?,
        destination: URL?
    ) -> ForegroundCopyRelayResult {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("Foreground relay received an empty value.")
            return .init(copied: false, field: field, destination: destination)
        }

        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        ClipboardWriter().copyText(value)
        let after = pasteboard.changeCount
        let matches = pasteboard.string == value
        let copied = after > before && matches
        logger.notice(
            "Foreground relay copy finished. field=\(field?.rawValue ?? "test", privacy: .public) before=\(before) after=\(after) matches=\(matches) characters=\(value.count)"
        )
        return .init(copied: copied, field: field, destination: destination)
    }
}
