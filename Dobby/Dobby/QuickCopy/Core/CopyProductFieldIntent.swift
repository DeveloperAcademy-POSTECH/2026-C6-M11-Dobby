import AppIntents
import ActivityKit
import OSLog
import UIKit
import UniformTypeIdentifiers

struct CopyProductFieldIntent: LiveActivityIntent {
    private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "QuickCopy")

    static var title: LocalizedStringResource = "상품 정보 복사"
    static var openAppWhenRun = false
    @Parameter(title: "세션") var sessionID: String
    @Parameter(title: "항목") var field: String
    init() {}
    init(sessionID: String, field: String) { self.sessionID = sessionID; self.field = field }

    @MainActor func perform() async throws -> some IntentResult {
        Self.logger.notice("[1/6] Live Activity copy button tapped. session=\(sessionID, privacy: .public) field=\(field, privacy: .public)")

        guard let id = UUID(uuidString: sessionID) else {
            Self.logger.error("[FAILED 2/6] Invalid session UUID: \(sessionID, privacy: .public)")
            return .result()
        }
        guard let copyField = ProductCopyField(rawValue: field) else {
            Self.logger.error("[FAILED 2/6] Unknown copy field: \(field, privacy: .public)")
            return .result()
        }
        Self.logger.notice("[2/6] Intent parameters decoded")

        guard let session = ProductCopyStore.load() else {
            Self.logger.error("[FAILED 3/6] No valid copy session in app UserDefaults")
            return .result()
        }
        guard session.id == id else {
            Self.logger.error("[FAILED 3/6] Session mismatch. requested=\(id.uuidString, privacy: .public) stored=\(session.id.uuidString, privacy: .public)")
            return .result()
        }
        Self.logger.notice("[3/6] Copy session loaded. product=\(session.productID, privacy: .public)")

        let activeActivities = Activity<ProductCopyAttributes>.activities
        guard let activity = activeActivities.first(where: {
            $0.attributes.sessionID == id && ($0.activityState == .active || $0.activityState == .stale)
        }) else {
            Self.logger.error("[FAILED 4/6] Matching Live Activity not found. activityCount=\(activeActivities.count)")
            return .result()
        }
        Self.logger.notice("[4/6] Matching Live Activity found. state=\(String(describing: activity.activityState), privacy: .public)")

        let value = session.payload.value(for: copyField)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.logger.error("[FAILED 5/6] Copy value is empty. field=\(copyField.rawValue, privacy: .public)")
            return .result()
        }

        let pasteboard = UIPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        let processName = ProcessInfo.processInfo.processName
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        Self.logger.notice(
            "[5/6] Pasteboard write starting. process=\(processName, privacy: .public) bundle=\(bundleIdentifier, privacy: .public) beforeChangeCount=\(beforeChangeCount) characterCount=\(value.count)"
        )
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true]
        )
        let afterChangeCount = pasteboard.changeCount
        let readBackMatches = pasteboard.string == value
        if afterChangeCount > beforeChangeCount && readBackMatches {
            Self.logger.notice("[6/6] Pasteboard write verified. afterChangeCount=\(afterChangeCount)")
        } else {
            Self.logger.error(
                "[FAILED 6/6] Pasteboard write could not be verified. before=\(beforeChangeCount) after=\(afterChangeCount) readBackMatches=\(readBackMatches) process=\(processName, privacy: .public) bundle=\(bundleIdentifier, privacy: .public)"
            )
        }

        await activity.update(ActivityContent(state: .init(lastAttemptedField: copyField.rawValue, message: "입력란에 붙여넣어주세요"), staleDate: session.createdAt.addingTimeInterval(8 * 3600)))
        Self.logger.notice("Live Activity status message updated")
        return .result()
    }
}
