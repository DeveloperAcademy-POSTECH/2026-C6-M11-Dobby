import ActivityKit
import AppIntents

struct CopyProductFieldIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "상품 정보 복사"
    static var openAppWhenRun = false

    @Parameter(title: "세션") var sessionID: String
    @Parameter(title: "항목") var field: String
    @Parameter(title: "복사할 내용") var text: String

    init() {}

    init(sessionID: String, field: ProductCopyField, text: String) {
        self.sessionID = sessionID
        self.field = field.rawValue
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID),
              let copyField = ProductCopyField(rawValue: field),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let activity = Activity<ProductCopyAttributes>.activities.first(where: {
                  $0.attributes.sessionID == id
                      && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            return .result()
        }

        ClipboardWriter().copyText(text)
        await activity.update(ActivityContent(
            state: .init(lastAttemptedField: copyField.rawValue, message: copyField.copiedMessage),
            staleDate: nil
        ))
        return .result()
    }
}
