import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var message: String?

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
                    Button(action: openPrivacyPolicy) {
                        SettingsNavigationRow(title: "개인정보 처리방침", systemImage: "arrow.up.right")
                    }
                }

                SettingsSection(title: "지원") {
                    Button(action: openSupportMail) {
                        SettingsNavigationRow(
                            title: "문의하기",
                            subtitle: "chak 이용 중 궁금한 점이나 불편한 점을 알려주세요.",
                            systemImage: "arrow.up.right"
                        )
                    }
                }

                SettingsSection(title: "앱 정보") {
                    SettingsTextGroup(title: SettingsInformation.versionText)
                }
            }
            .padding(.vertical, 8)
        }
        .background(SettingsStyle.background)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
        .alert("설정 안내", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func openPrivacyPolicy() {
        guard let url = SettingsInformation.privacyPolicyURL else {
            message = "개인정보 처리방침 주소를 확인할 수 없어요."
            return
        }
        open(url, failureMessage: "개인정보 처리방침을 열 수 없어요.")
    }

    private func openSupportMail() {
        guard let url = SettingsInformation.supportMailURL else {
            message = "문의 메일 주소를 확인할 수 없어요."
            return
        }
        open(url, failureMessage: "메일 작성 화면을 열 수 없어요.")
    }

    private func open(_ url: URL, failureMessage: String) {
        openURL(url) { accepted in
            guard !accepted else { return }
            message = failureMessage
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
