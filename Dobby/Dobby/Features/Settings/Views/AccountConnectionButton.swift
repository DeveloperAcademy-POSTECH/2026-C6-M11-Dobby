import SwiftUI

enum AccountConnectionButtonState {
    case connect
    case connecting
    case disconnect
    case disconnecting
}

struct AccountConnectionButton: View {
    let state: AccountConnectionButtonState
    let action: () -> Void

    var body: some View {
        switch state {
        case .connect:
            ConnectAccountButton(action: action)
        case .connecting:
            ConnectingAccountButton()
        case .disconnect:
            DisconnectAccountButton(action: action)
        case .disconnecting:
            DisconnectingAccountButton()
        }
    }
}

#Preview("연결하기") {
    AccountConnectionButton(
        state: .connect,
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}

#Preview("연결 중") {
    AccountConnectionButton(
        state: .connecting,
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}

#Preview("연결 해제") {
    AccountConnectionButton(
        state: .disconnect,
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}

#Preview("연결 해제 중") {
    AccountConnectionButton(
        state: .disconnecting,
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}
