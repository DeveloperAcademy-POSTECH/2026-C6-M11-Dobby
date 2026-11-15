import SwiftUI

struct SettingsNavigationRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 27) {
            SettingsTextGroup(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(width: 16, height: 20)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    SettingsNavigationRow(
        title: "연결된 계정 관리",
        systemImage: "chevron.right"
    )
    .padding(20)
    .background(SettingsStyle.background)
}
