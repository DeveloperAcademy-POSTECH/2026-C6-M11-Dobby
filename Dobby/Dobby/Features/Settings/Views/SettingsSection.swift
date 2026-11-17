import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(title: String, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .font(SettingsTypography.sectionTitle)
                .tracking(SettingsTypography.sectionTitleTracking)
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(height: 29, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    SettingsSection(title: "기본 설정") {
        Text("연결된 계정 관리")
    }
    .padding(20)
    .background(SettingsStyle.background)
}
