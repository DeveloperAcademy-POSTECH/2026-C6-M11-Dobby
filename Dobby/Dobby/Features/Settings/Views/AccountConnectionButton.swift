import SwiftUI

struct AccountConnectionButton: View {
    let state: AccountConnectionState
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(state.title)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(state.foregroundStyle)
                    .padding(8)
            }
        }
        .background(SettingsStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(SettingsStyle.separator, lineWidth: 1)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}

#Preview {
    AccountConnectionButton(
        state: .connect,
        isWorking: false,
        action: {}
    )
    .padding(20)
    .background(SettingsStyle.background)
}
