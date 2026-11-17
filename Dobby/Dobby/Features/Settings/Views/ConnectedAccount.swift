import SwiftUI

struct ConnectedAccount: View {
    let item: ConnectedAccountItem
    let action: () -> Void

    var body: some View {
        HStack(spacing: 27) {
            ConnectedAccountIdentity(
                imageName: imageName,
                title: title,
                account: item.state.account
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            AccountConnectionButton(
                state: buttonState,
                action: action
            )
            .accessibilityLabel(accountActionLabel)
            .accessibilityValue(item.state.account ?? "")
        }
        .accessibilityElement(children: .contain)
    }

    private var platformTitle: String {
        switch item.platform {
        case .instagram:
            "인스타그램"
        case .cafe24:
            "카페24"
        }
    }

    private var accountActionLabel: String {
        if item.isWorking {
            return "\(platformTitle) 계정 \(item.state.isConnected ? "연결 해제 중" : "연결 중")"
        }
        return "\(platformTitle) 계정 \(item.state.isConnected ? "연결 해제" : "연결하기")"
    }

    private var imageName: String {
        switch item.platform {
        case .instagram:
            "InstagramLogo"
        case .cafe24:
            "Cafe24Logo"
        }
    }

    private var title: String {
        if item.state.isConnected {
            "\(platformTitle) 계정 연결 완료"
        } else {
            "\(platformTitle) 계정 연결 전"
        }
    }

    private var buttonState: AccountConnectionButtonState {
        switch (item.state.isConnected, item.isWorking) {
        case (false, false):
            .connect
        case (false, true):
            .connecting
        case (true, false):
            .disconnect
        case (true, true):
            .disconnecting
        }
    }
}

#Preview("ConnectedAccount - 연결 완료") {
    ConnectedAccount(
        item: ConnectedAccountItem(
            platform: .instagram,
            state: .connected(account: "@dobby"),
            isWorking: false
        ),
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}

#Preview("ConnectedAccount - 연결 전") {
    ConnectedAccount(
        item: ConnectedAccountItem(
            platform: .cafe24,
            state: .disconnected,
            isWorking: false
        ),
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}
