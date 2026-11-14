import SwiftUI

enum AccountConnectionState {
    case connect
    case disconnect

    var title: String {
        switch self {
        case .connect: "연결하기"
        case .disconnect: "연결 해제"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .connect: SettingsStyle.buttonText
        case .disconnect: SettingsStyle.destructive
        }
    }
}

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
                state: actionState,
                isWorking: item.isWorking,
                action: action
            )
        }
    }

    private var platformTitle: String {
        switch item.platform {
        case .instagram:
            "인스타그램"
        case .cafe24:
            "카페24"
        }
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

    private var actionState: AccountConnectionState {
        item.state.isConnected ? .disconnect : .connect
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
