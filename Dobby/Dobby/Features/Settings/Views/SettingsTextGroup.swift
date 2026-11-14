import SwiftUI

struct SettingsTextGroup: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsTypography.labelMedium)
                .tracking(SettingsTypography.labelMediumTracking)
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(height: 20, alignment: .leading)
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(SettingsStyle.secondaryText)
                    .frame(height: 16, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

#Preview {
    SettingsTextGroup(
        title: "문의하기",
        subtitle: "chak 이용 중 궁금한 점을 알려주세요."
    )
    .padding(20)
    .background(SettingsStyle.background)
}
