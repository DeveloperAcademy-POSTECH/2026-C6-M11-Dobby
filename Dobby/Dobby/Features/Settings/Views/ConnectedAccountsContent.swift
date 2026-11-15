import SwiftUI

private enum ConnectedAccountsContentStyle {
    static func separatorSpacing(for state: ConnectedAccountState) -> CGFloat {
        state.isConnected ? 16 : 24
    }
}

struct ConnectedAccountsContent: View {
    let state: ConnectedAccountsState
    let onAction: (ConnectedAccountPlatform) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConnectedAccount(
                item: state.instagram,
                action: { onAction(.instagram) }
            )

            Spacer()
                .frame(
                    height: ConnectedAccountsContentStyle.separatorSpacing(
                        for: state.instagram.state
                    )
                )

            SettingsStyle.separator
                .frame(height: 1)

            Spacer()
                .frame(
                    height: ConnectedAccountsContentStyle.separatorSpacing(
                        for: state.cafe24.state
                    )
                )

            ConnectedAccount(
                item: state.cafe24,
                action: { onAction(.cafe24) }
            )
        }
    }
}

#Preview("연결 전") {
    NavigationStack {
        ConnectedAccountsContent(
            state: ConnectedAccountsState(
                instagram: ConnectedAccountItem(
                    platform: .instagram,
                    state: .disconnected,
                    isWorking: false
                ),
                cafe24: ConnectedAccountItem(
                    platform: .cafe24,
                    state: .disconnected,
                    isWorking: false
                )
            ),
            onAction: { _ in }
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("연결 완료") {
    NavigationStack {
        ConnectedAccountsContent(
            state: ConnectedAccountsState(
                instagram: ConnectedAccountItem(
                    platform: .instagram,
                    state: .connected(account: "@dlstnaos"),
                    isWorking: false
                ),
                cafe24: ConnectedAccountItem(
                    platform: .cafe24,
                    state: .connected(account: "@dobbyisvintage.cafe24.com"),
                    isWorking: false
                )
            ),
            onAction: { _ in }
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("인스타그램만 연결") {
    NavigationStack {
        ConnectedAccountsContent(
            state: ConnectedAccountsState(
                instagram: ConnectedAccountItem(
                    platform: .instagram,
                    state: .connected(account: "@dobby"),
                    isWorking: false
                ),
                cafe24: ConnectedAccountItem(
                    platform: .cafe24,
                    state: .disconnected,
                    isWorking: false
                )
            ),
            onAction: { _ in }
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("카페24만 연결") {
    NavigationStack {
        ConnectedAccountsContent(
            state: ConnectedAccountsState(
                instagram: ConnectedAccountItem(
                    platform: .instagram,
                    state: .disconnected,
                    isWorking: false
                ),
                cafe24: ConnectedAccountItem(
                    platform: .cafe24,
                    state: .connected(account: "@dobbyisvintage.cafe24.com"),
                    isWorking: false
                )
            ),
            onAction: { _ in }
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}
