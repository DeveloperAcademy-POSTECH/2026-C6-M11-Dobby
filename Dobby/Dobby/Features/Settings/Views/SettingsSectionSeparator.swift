import SwiftUI

struct SettingsSectionSeparator: View {
    var body: some View {
        SettingsStyle.sectionSeparator
            .frame(height: 6)
    }
}

#Preview {
    SettingsSectionSeparator()
        .padding(.vertical, 20)
        .background(SettingsStyle.background)
}
