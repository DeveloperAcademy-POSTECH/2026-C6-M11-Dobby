import AppIntents
import OSLog
import UIKit

private enum AppShortcutCopyPerformer {
    static let logger = Logger(subsystem: "com.dobby.Dobby", category: "AppShortcutCopy")

    @MainActor
    static func copy(_ field: ProductCopyField) -> Bool {
        guard let session = ProductCopyStore.load() else {
            logger.error("App Shortcut copy failed: no active product session. field=\(field.rawValue, privacy: .public)")
            return false
        }

        let value = session.payload.value(for: field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("App Shortcut copy failed: empty value. field=\(field.rawValue, privacy: .public)")
            return false
        }

        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        ClipboardWriter().copyText(value)
        let after = pasteboard.changeCount
        let matches = pasteboard.string == value
        logger.notice(
            "App Shortcut copy finished. field=\(field.rawValue, privacy: .public) before=\(before) after=\(after) matches=\(matches) characters=\(value.count)"
        )
        return after > before && matches
    }

    @MainActor
    static func copyTestValue() -> Bool {
        let value = "FF-A-56000"
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        ClipboardWriter().copyText(value)
        let after = pasteboard.changeCount
        let matches = pasteboard.string == value
        logger.notice(
            "App Shortcut test copy finished. before=\(before) after=\(after) matches=\(matches)"
        )
        return after > before && matches
    }
}

struct DobbyTestCopyIntent: AppIntent {
    static let title: LocalizedStringResource = "Dobby 테스트 복사"
    static let description = IntentDescription("FF-A-56000을 클립보드에 복사합니다.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = AppShortcutCopyPerformer.copyTestValue()
        return .result(dialog: copied ? "FF-A-56000이 복사되었습니다." : "복사하지 못했습니다. Dobby를 열어 다시 시도해주세요.")
    }
}

struct DobbyCopyProductNameIntent: AppIntent {
    static let title: LocalizedStringResource = "Dobby 상품명 복사"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = AppShortcutCopyPerformer.copy(.productName)
        return .result(dialog: copied ? "상품명이 복사되었습니다." : "복사할 상품 정보가 없습니다.")
    }
}

struct DobbyCopyDescriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Dobby 설명 복사"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = AppShortcutCopyPerformer.copy(.description)
        return .result(dialog: copied ? "설명이 복사되었습니다." : "복사할 상품 정보가 없습니다.")
    }
}

struct DobbyCopyBrandIntent: AppIntent {
    static let title: LocalizedStringResource = "Dobby 브랜드명 복사"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = AppShortcutCopyPerformer.copy(.brand)
        return .result(dialog: copied ? "브랜드명이 복사되었습니다." : "복사할 상품 정보가 없습니다.")
    }
}

struct DobbyCopyMeasurementsIntent: AppIntent {
    static let title: LocalizedStringResource = "Dobby 실측 사이즈 복사"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = AppShortcutCopyPerformer.copy(.measurements)
        return .result(dialog: copied ? "실측 사이즈가 복사되었습니다." : "복사할 상품 정보가 없습니다.")
    }
}

struct DobbyCopyAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DobbyTestCopyIntent(),
            phrases: ["\(.applicationName) 테스트 복사"],
            shortTitle: "Dobby 테스트 복사",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: DobbyCopyProductNameIntent(),
            phrases: ["\(.applicationName) 상품명 복사"],
            shortTitle: "Dobby 상품명 복사",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: DobbyCopyDescriptionIntent(),
            phrases: ["\(.applicationName) 설명 복사"],
            shortTitle: "Dobby 설명 복사",
            systemImageName: "text.alignleft"
        )
        AppShortcut(
            intent: DobbyCopyBrandIntent(),
            phrases: ["\(.applicationName) 브랜드명 복사"],
            shortTitle: "Dobby 브랜드명 복사",
            systemImageName: "building.2"
        )
        AppShortcut(
            intent: DobbyCopyMeasurementsIntent(),
            phrases: ["\(.applicationName) 실측 사이즈 복사"],
            shortTitle: "Dobby 실측 사이즈 복사",
            systemImageName: "ruler"
        )
    }
}
