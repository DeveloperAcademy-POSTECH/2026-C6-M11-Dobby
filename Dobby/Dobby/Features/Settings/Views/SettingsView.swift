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
    @State private var model = ConnectedAccountsModel()
    @State private var cafe24MallID = ""
    @State private var isEnteringCafe24MallID = false
    @State private var disconnectingPlatform: ConnectedAccountPlatform?

    var body: some View {
        VStack(spacing: 0) {
            ConnectedAccountRow(
                title: model.instagramAccount == nil ? "인스타그램 계정 연결 전" : "인스타그램 계정 연결 완료",
                subtitle: model.instagramAccount.map { "@\($0.username)" },
                imageName: "InstagramLogo",
                actionTitle: model.instagramAccount == nil ? "연결하기" : "연결 해제",
                role: model.instagramAccount == nil ? nil : .destructive,
                isWorking: model.isLoading(.instagram)
            ) {
                if model.instagramAccount == nil {
                    Task { await model.connectInstagram() }
                } else {
                    disconnectingPlatform = .instagram
                }
            }

            Divider()
                .padding(.leading, 52)

            ConnectedAccountRow(
                title: model.cafe24MallID == nil ? "카페24 계정 연결 전" : "카페24 계정 연결 완료",
                subtitle: model.cafe24MallID.map { "@\($0).cafe24.com" },
                imageName: "Cafe24Logo",
                actionTitle: model.cafe24MallID == nil ? "연결하기" : "연결 해제",
                role: model.cafe24MallID == nil ? nil : .destructive,
                isWorking: model.isLoading(.cafe24)
            ) {
                if model.cafe24MallID == nil {
                    isEnteringCafe24MallID = true
                } else {
                    disconnectingPlatform = .cafe24
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutralWhite"))
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.requestAccounts() }
        .alert("카페24 계정 연결", isPresented: $isEnteringCafe24MallID) {
            TextField("쇼핑몰 ID", text: $cafe24MallID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("연결하기") {
                let mallID = cafe24MallID
                cafe24MallID = ""
                Task { await model.connectCafe24(mallID: mallID) }
            }
            Button("취소", role: .cancel) {
                cafe24MallID = ""
            }
        } message: {
            Text("카페24 쇼핑몰 관리자 주소의 ID를 입력해 주세요.")
        }
        .confirmationDialog(
            "\(disconnectingPlatform?.title ?? "") 연결을 해제할까요?",
            isPresented: Binding(
                get: { disconnectingPlatform != nil },
                set: { if !$0 { disconnectingPlatform = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("연결 해제", role: .destructive) {
                guard let platform = disconnectingPlatform else { return }
                disconnectingPlatform = nil
                Task { await model.disconnect(platform) }
            }
            Button("취소", role: .cancel) {
                disconnectingPlatform = nil
            }
        }
        .alert("계정 연결 안내", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

private struct ConnectedAccountRow: View {
    let title: String
    let subtitle: String?
    let imageName: String
    let actionTitle: String
    let role: ButtonRole?
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 68)
            } else {
                Button(actionTitle, role: role, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 16)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
