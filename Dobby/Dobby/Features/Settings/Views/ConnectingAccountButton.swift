import SwiftUI

struct ConnectingAccountButton: View {
    
    var body: some View {
        Button(action: {}) {
            Text("연결하기")
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .opacity(0)
                    .overlay {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(SettingsStyle.buttonText)
                    }
            .frame(width: 48, height: 20)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
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
        .accessibilityLabel("연결 중")
    }
}

#Preview {
    ConnectingAccountButton()
        .padding(20)
        .background(SettingsStyle.background)
}
