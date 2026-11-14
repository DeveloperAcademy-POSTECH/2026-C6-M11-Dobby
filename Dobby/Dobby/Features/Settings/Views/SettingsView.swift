import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsHeader()

            ScrollView {
                SettingsContent(
                    onPrivacyPolicy: openPrivacyPolicy,
                    onSupportMail: openSupportMail
                )
                .padding(.top, 29)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 3)
        .background(SettingsStyle.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
