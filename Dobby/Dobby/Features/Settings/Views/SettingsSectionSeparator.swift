import SwiftUI

struct SettingsSectionSeparator: View {
    var body: some View {
        Color("BrandNeutral100")
            .frame(height: 6)
    }
}

#Preview {
    SettingsSectionSeparator()
        .padding(.vertical, 20)
        .background(SettingsStyle.background)
}
