import SwiftUI

struct DisconnectingAccountButton: View {
    var body: some View {
        Button(action: {}) {
            Text("연결 해제")
                .font(SettingsTypography.labelSmall)
                .tracking(SettingsTypography.labelSmallTracking)
                .opacity(0)
                .overlay {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(SettingsStyle.buttonText)
                }
                .padding(8)
        }
        .background(SettingsStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .inset(by: 0.5)
                .stroke(SettingsStyle.separator, lineWidth: 1)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("연결 해제 중")
    }
}

#Preview {
    DisconnectingAccountButton()
        .padding(20)
        .background(SettingsStyle.background)
}
