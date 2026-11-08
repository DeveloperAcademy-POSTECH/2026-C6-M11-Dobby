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

private struct SettingsContent: View {
    @AppStorage(ProductAutofillFlowPreference.key, store: ProductAutofillFlowPreference.defaults)
    private var autofillFlow = ProductAutofillFlow.photoSelection.rawValue
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

                VStack(alignment: .leading, spacing: 12) {
                    Text("AI 생성 방식")
                        .font(SettingsTypography.labelMedium)
                        .tracking(SettingsTypography.labelMediumTracking)
                        .foregroundStyle(SettingsStyle.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    SettingsSelectionRow(title: "A안(사진 선택 뷰 토글)", isSelected: !usesInformationFlow) {
                        autofillFlow = ProductAutofillFlow.photoSelection.rawValue
                    }
                    .accessibilityIdentifier("settings.aiFlow.a")

                    SettingsSelectionRow(title: "B안(제품 정보 입력 뷰)", isSelected: usesInformationFlow) {
                        autofillFlow = ProductAutofillFlow.information.rawValue
                    }
                    .accessibilityIdentifier("settings.aiFlow.b")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsSectionSeparator()

            #if DEBUG
            SettingsSection(title: "개발 테스트") {
                NavigationLink {
                    ProductAutofillTestView()
                } label: {
                    SettingsNavigationRow(title: "AI 정보 생성 테스트",
                        subtitle: "앨범 사진으로 생성 결과 확인", systemImage: "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.aiTest")
            }

            SettingsSectionSeparator()
            #endif

            SettingsSection(title: "정책") {
                Button(action: onPrivacyPolicy) {
                    SettingsNavigationRow(title: "개인정보 처리방침", systemImage: "arrow.up.right")
                }
                .buttonStyle(.plain)
            }

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

            SettingsSectionSeparator()

            SettingsSection(title: "앱 정보", spacing: 12) {
                SettingsTextGroup(title: SettingsInformation.versionText)
            }
        }
    }

    private var usesInformationFlow: Bool {
        ProductAutofillFlowPreference.resolve(rawValue: autofillFlow) == .information
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
