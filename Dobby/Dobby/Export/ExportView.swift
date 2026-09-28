import SwiftUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var history: ExportHistoryStore
    @State private var isShowingOpenError = false
    @State private var isOpeningLink = false

    @MainActor
    init(history: ExportHistoryStore? = nil) {
        _history = State(initialValue: history ?? ExportHistoryStore())
    }

    var body: some View {
        NavigationStack {
            VStack {
                ExportChannelListView(
                    openedChannels: history.openedChannels,
                    onSelectChannel: didSelectChannel
                )
            }
            .padding(32)
            .navigationTitle("내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.labelNormal)
                    .accessibilityLabel("닫기")
                    .accessibilityIdentifier("export.close")
                }
            }
            .disabled(isOpeningLink)
            .alert("페이지를 열 수 없습니다", isPresented: $isShowingOpenError) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("잠시 후 다시 시도해 주세요.")
            }
        }
    }

    /// 링크 열기 결과를 기록하고 거절된 요청은 알림으로 안내합니다.
    private func didSelectChannel(_ channel: ExportChannel) {
        guard !isOpeningLink else { return }
        isOpeningLink = true
        openURL(channel.destinationURL) { accepted in
            history.recordOpenResult(for: channel, accepted: accepted)
            isOpeningLink = false
            isShowingOpenError = !accepted
        }
    }
}

#if DEBUG
/// Preview 전용 영역을 초기화해 실제 방문 기록과 분리합니다.
@MainActor
private func makePreviewHistory(
    scenario: String,
    openedChannels: Set<ExportChannel> = []
) -> ExportHistoryStore {
    let suiteName = "com.dobby.export.preview.\(scenario)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Preview 저장소를 생성하지 못했습니다.")
    }
    defaults.removePersistentDomain(forName: suiteName)
    openedChannels.forEach {
        defaults.set(true, forKey: $0.openedLinkStorageKey)
    }
    return ExportHistoryStore(defaults: defaults)
}

#Preview("처음 방문") {
    ExportView(history: makePreviewHistory(scenario: "empty"))
}

#Preview("Instagram 방문") {
    ExportView(
        history: makePreviewHistory(
            scenario: "instagram",
            openedChannels: [.instagram]
        )
    )
}

#Preview("모든 채널 방문") {
    ExportView(
        history: makePreviewHistory(
            scenario: "all",
            openedChannels: Set(ExportChannel.allCases)
        )
    )
}

#Preview("작은 화면 · 큰 글자", traits: .fixedLayout(width: 320, height: 568)) {
    ExportView(
        history: makePreviewHistory(
            scenario: "accessibility",
            openedChannels: [.instagram]
        )
    )
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("탭하면 방문 체크") {
    ExportView(history: makePreviewHistory(scenario: "success"))
        .environment(\.openURL, OpenURLAction { _ in .handled })
}

#Preview("탭하면 실패 안내") {
    ExportView(history: makePreviewHistory(scenario: "failure"))
        .environment(\.openURL, OpenURLAction { _ in .discarded })
}
#endif
