import SwiftUI

struct SettingsContent: View {
    let onPrivacyPolicy: () -> Void
    let onSupportMail: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            SettingsSection(title: "기본 설정") {
                NavigationLink {
                    ConnectedAccountsView()
                } label: {
                    SettingsNavigationRow(title: "연결된 계정 관리", systemImage: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            SettingsSectionSeparator()

            SettingsSection(title: "정책") {
                Button(action: onPrivacyPolicy) {
                    SettingsNavigationRow(title: "개인정보 처리방침", systemImage: "arrow.up.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            SettingsSectionSeparator()

            SettingsSection(title: "지원") {
                Button(action: onSupportMail) {
                    SettingsNavigationRow(
                        title: "문의하기",
                        subtitle: "chak 이용 중 궁금한 점이나 불편한 점을 알려주세요.",
                        systemImage: "arrow.up.right"
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)

            SettingsSectionSeparator()

            SettingsSection(title: "앱 정보", spacing: 12) {
                SettingsTextGroup(title: SettingsInformation.versionText)
            }
            .padding(.horizontal, 20)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsContent(
            onPrivacyPolicy: {},
            onSupportMail: {}
        )
        .padding(.vertical, 20)
        .background(SettingsStyle.background)
    }
}
