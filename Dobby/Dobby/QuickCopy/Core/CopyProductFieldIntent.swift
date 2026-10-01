import AppIntents
import ActivityKit
import UIKit
import UniformTypeIdentifiers

struct CopyProductFieldIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "상품 정보 복사 시도"
    static var openAppWhenRun = false
    @Parameter(title: "세션") var sessionID: String
    @Parameter(title: "항목") var field: String
    init() {}
    init(sessionID: String, field: String) { self.sessionID = sessionID; self.field = field }

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID), let field = ProductCopyField(rawValue: field),
              let session = ProductCopyStore.load(), session.id == id, session.mode == .direct,
              let activity = Activity<ProductCopyAttributes>.activities.first(where: {
                  $0.attributes.sessionID == id && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            CopyJournal.append("직접 복사 거절 · 종료/만료/잘못된 세션")
            return .result()
        }
        let value = session.payload.value(for: field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .result() }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
        CopyJournal.append("\(session.channel.title) · \(field.title) · 백그라운드 쓰기 시도 (실제 수신 미검증)")
        await activity.update(ActivityContent(state: .init(lastAttemptedField: field.rawValue, message: "\(field.title) 시도 · 붙여넣기 확인 필요"), staleDate: session.createdAt.addingTimeInterval(8 * 3600)))
        return .result()
    }
}

@MainActor enum CopyJournal {
    private static let key = "quickCopy.journal.v1"
    static func entries() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func append(_ message: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) · \(message)"
        UserDefaults.standard.set(Array(([line] + entries()).prefix(300)), forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
