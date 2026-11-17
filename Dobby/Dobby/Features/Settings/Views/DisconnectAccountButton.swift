import SwiftUI

struct DisconnectAccountButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("연결 해제")
                .font(SettingsTypography.labelSmall)
                .tracking(SettingsTypography.labelSmallTracking)
                .foregroundStyle(SettingsStyle.destructive)
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
    }
}

#Preview {
    DisconnectAccountButton(action: {})
        .padding(20)
        .background(SettingsStyle.background)
}
