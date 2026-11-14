import SwiftUI

struct SettingsSectionSeparator: View {
    var body: some View {
        SettingsStyle.sectionSeparator
            .frame(height: 6)
            .padding(.horizontal, -20)
    }
}

#Preview {
    SettingsSectionSeparator()
        .padding(.horizontal, 20)
        .background(SettingsStyle.background)
}
