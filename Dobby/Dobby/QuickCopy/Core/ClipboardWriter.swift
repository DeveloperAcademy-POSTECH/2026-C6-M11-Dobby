import UIKit
import UniformTypeIdentifiers

@MainActor
struct ClipboardWriter {
    func copyText(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true]
        )
    }
}
