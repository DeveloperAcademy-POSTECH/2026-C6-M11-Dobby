import AppIntents
import ActivityKit
import UIKit
import UniformTypeIdentifiers

struct CopyProductFieldIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "상품 정보 복사"
    static var openAppWhenRun = false
    @Parameter(title: "세션") var sessionID: String
    @Parameter(title: "항목") var field: String
    init() {}
    init(sessionID: String, field: String) { self.sessionID = sessionID; self.field = field }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID), let field = ProductCopyField(rawValue: field),
              let session = ProductCopyStore.load(), session.id == id,
              let activity = Activity<ProductCopyAttributes>.activities.first(where: {
                  $0.attributes.sessionID == id && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            return .result()
        }
        let value = session.payload.value(for: field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .result() }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
        await activity.update(ActivityContent(state: .init(lastAttemptedField: field.rawValue, message: "입력란에 붙여넣어주세요"), staleDate: session.createdAt.addingTimeInterval(8 * 3600)))
        return .result()
    }
}
