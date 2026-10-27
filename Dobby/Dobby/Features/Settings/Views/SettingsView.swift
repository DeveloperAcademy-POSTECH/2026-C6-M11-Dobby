import SwiftUI

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                SettingsSection(title: "기본 설정") {
                    NavigationLink {
                        ConnectedAccountsView()
                    } label: {
                        SettingsNavigationRow(title: "연결된 계정 관리", systemImage: "chevron.right")
                    }
                }

                SettingsSection(title: "정책") {
                    Button(action: {}) {
                        SettingsNavigationRow(title: "개인정보 처리방침", systemImage: "arrow.up.right")
                    }
                }

                SettingsSection(title: "지원") {
                    Button(action: {}) {
                        SettingsNavigationRow(
                            title: "문의하기",
                            subtitle: "chak 이용 중 궁금한 점이나 불편한 점을 알려주세요.",
                            systemImage: "arrow.up.right"
                        )
                    }
                }

                SettingsSection(title: "앱 정보") {
                    Text("현재 버전")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color("BackgroundNomalAlternative"))
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("BrandNeutralWhite"))
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct ConnectedAccountsView: View {
    var body: some View {
        VStack(spacing: 0) {
            ConnectedAccountRow(
                title: "인스타그램 계정 연결 전",
                imageName: "InstagramLogo",
                actionTitle: "연결하기"
            )

            Divider()
                .padding(.leading, 52)

            ConnectedAccountRow(
                title: "카페24 계정 연결 전",
                imageName: "Cafe24Logo",
                actionTitle: "연결하기"
            )

            Spacer()
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutralWhite"))
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConnectedAccountRow: View {
    let title: String
    let imageName: String
    let actionTitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            Text(title)
                .font(.subheadline)

            Spacer()

            Button(actionTitle, action: {})
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 16)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
