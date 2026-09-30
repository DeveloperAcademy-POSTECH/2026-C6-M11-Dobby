import ActivityKit
import Observation
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class LegacyCopyBridge {
    private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "QuickCopyBridge")

    private(set) var message = "앱 경유 복사 요청을 기다리고 있습니다."
    private var pending: CopyRequest?

    func receive(_ url: URL) {
        guard let request = CopyRoute.parse(url) else { return }
        pending = request
        message = "Dobby가 활성화되면 복사합니다."
        Self.logger.notice("Foreground bridge received. session=\(request.sessionID.uuidString, privacy: .public) field=\(request.field.rawValue, privacy: .public)")
    }

    func processIfActive(_ phase: ScenePhase) {
        guard phase == .active,
              UIApplication.shared.applicationState == .active,
              let request = pending else { return }
        pending = nil

        guard let session = ProductCopyStore.load(),
              session.id == request.sessionID,
              session.interactionMode != .direct,
              let activity = Activity<ProductCopyAttributes>.activities.first(where: {
                  $0.attributes.sessionID == session.id
                      && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            message = "종료되었거나 일치하지 않는 복사 도우미입니다."
            Self.logger.error("Foreground bridge rejected: invalid session or activity")
            return
        }

        let originalValue = session.payload.value(for: request.field)
        let value = session.diagnosticToken.map {
            "[DOBBY-\(request.field.rawValue)-\($0)] \(originalValue)"
        } ?? originalValue
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "복사할 값이 없습니다."
            return
        }

        let attemptID = UUID()
        let startedAt = Date()
        let pasteboard = UIPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        write(value, to: pasteboard, strategy: session.effectiveWriteStrategy)
        let afterChangeCount = pasteboard.changeCount
        let readBackMatches = pasteboard.string == value
        let result = CopyDiagnosticResult(
            id: attemptID,
            sessionID: session.id,
            field: request.field,
            executionMode: "foreground-bridge",
            canContinueInForeground: true,
            processName: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            beforeChangeCount: beforeChangeCount,
            afterChangeCount: afterChangeCount,
            readBackMatches: readBackMatches,
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            createdAt: Date(),
            writeStrategy: session.effectiveWriteStrategy,
            diagnosticToken: session.diagnosticToken,
            diagnosticCondition: session.diagnosticCondition
        )
        ProductCopyStore.saveDiagnostic(result)

        message = result.writeVerified
            ? "Dobby에서 복사했습니다. 대상 앱으로 돌아가 붙여넣어주세요."
            : "Dobby가 활성화됐지만 복사를 확인하지 못했습니다."
        Task {
            await activity.update(ActivityContent(
                state: .init(lastAttemptedField: request.field.rawValue, message: message),
                staleDate: session.createdAt.addingTimeInterval(8 * 3_600)
            ))
        }
        Self.logger.notice("Foreground bridge completed. verified=\(result.writeVerified) before=\(beforeChangeCount) after=\(afterChangeCount)")

        if session.interactionMode == .foregroundAndOpen {
            UIApplication.shared.open(session.channel.destination) { accepted in
                Self.logger.notice("Foreground bridge destination open accepted=\(accepted)")
            }
        }
    }

    private func write(_ value: String, to pasteboard: UIPasteboard, strategy: CopyWriteStrategy) {
        switch strategy {
        case .setItemsLocalOnly:
            pasteboard.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
        case .setItemsShared:
            pasteboard.setItems([[UTType.utf8PlainText.identifier: value]], options: [:])
        case .stringProperty:
            pasteboard.string = value
        case .setObjects:
            pasteboard.setObjects([value as NSString], localOnly: true, expirationDate: nil)
        }
    }
}
