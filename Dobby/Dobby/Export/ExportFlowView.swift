import SwiftUI

struct ExportFlowView: View {
    @Environment(\.openURL) private var openURL
    @State private var history = ExportHistoryStore()
    @State private var isShowingOpenError = false
    @State private var isOpeningLink = false

    var body: some View {
        ExportView(openedChannels: history.openedChannels) { channel in
            didSelectChannel(channel)
        }
        .disabled(isOpeningLink)
        .alert("페이지를 열 수 없습니다", isPresented: $isShowingOpenError) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("잠시 후 다시 시도해 주세요.")
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

#Preview("링크 열기 실패") {
    ExportFlowView()
        .environment(\.openURL, OpenURLAction { _ in .discarded })
}
