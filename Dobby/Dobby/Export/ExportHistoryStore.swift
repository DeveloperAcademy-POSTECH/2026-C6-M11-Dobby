import Foundation
import Observation

/// OS가 링크 열기를 수락한 채널을 기기에 기록합니다.
@MainActor
@Observable
final class ExportHistoryStore {
    private(set) var openedChannels: Set<ExportChannel>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        openedChannels = Set(ExportChannel.availableCases.filter {
            defaults.bool(forKey: $0.openedLinkStorageKey)
        })
    }

    /// 성공한 요청만 저장하며 실패 시 과거 방문 기록을 유지합니다.
    func recordOpenResult(for channel: ExportChannel, accepted: Bool) {
        guard accepted else { return }
        defaults.set(true, forKey: channel.openedLinkStorageKey)
        openedChannels.insert(channel)
    }
}
