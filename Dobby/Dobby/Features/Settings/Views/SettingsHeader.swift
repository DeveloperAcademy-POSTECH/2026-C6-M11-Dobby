import SwiftUI

struct SettingsHeader: View {
    var body: some View {
        Text("설정")
            .font(SettingsTypography.screenTitle)
            .tracking(SettingsTypography.screenTitleTracking)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
    }
}

#Preview {
    SettingsHeader()
        .padding(20)
        .background(SettingsStyle.background)
}
