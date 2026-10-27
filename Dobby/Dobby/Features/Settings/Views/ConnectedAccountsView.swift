import SwiftUI

struct ConnectedAccountsView: View {
    @State private var model = ConnectedAccountsModel()
    @State private var cafe24MallID = ""
    @State private var isEnteringCafe24MallID = false
    @State private var disconnectingPlatform: ConnectedAccountPlatform?

    var body: some View {
        ConnectedAccountsContent(
            instagramSubtitle: model.instagramAccount.map { "@\($0.username)" },
            cafe24Subtitle: model.cafe24MallID.map { "@\($0).cafe24.com" },
            isLoadingInstagram: model.isLoading(.instagram),
            isLoadingCafe24: model.isLoading(.cafe24),
            onInstagramAction: handleInstagramAction,
            onCafe24Action: handleCafe24Action
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(SettingsStyle.background.ignoresSafeArea())
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(SettingsStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .tint(SettingsStyle.primaryText)
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

    private func handleInstagramAction() {
        if model.instagramAccount == nil {
            Task { await model.connectInstagram() }
        } else {
            disconnectingPlatform = .instagram
        }
    }

    private func handleCafe24Action() {
        if model.cafe24MallID == nil {
            isEnteringCafe24MallID = true
        } else {
            disconnectingPlatform = .cafe24
        }
    }
}

struct ConnectedAccountsContent: View {
    let instagramSubtitle: String?
    let cafe24Subtitle: String?
    let isLoadingInstagram: Bool
    let isLoadingCafe24: Bool
    let onInstagramAction: () -> Void
    let onCafe24Action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ConnectedAccountRow(
                title: instagramSubtitle == nil ? "인스타그램 계정 연결 전" : "인스타그램 계정 연결 완료",
                subtitle: instagramSubtitle,
                imageName: "InstagramLogo",
                actionState: instagramSubtitle == nil ? .connect : .disconnect,
                isWorking: isLoadingInstagram,
                action: onInstagramAction
            )

            SettingsStyle.separator
                .frame(height: 1)

            ConnectedAccountRow(
                title: cafe24Subtitle == nil ? "카페24 계정 연결 전" : "카페24 계정 연결 완료",
                subtitle: cafe24Subtitle,
                imageName: "Cafe24Logo",
                actionState: cafe24Subtitle == nil ? .connect : .disconnect,
                isWorking: isLoadingCafe24,
                action: onCafe24Action
            )
        }
    }
}

#Preview("연결 전") {
    NavigationStack {
        ConnectedAccountsContent(
            instagramSubtitle: nil,
            cafe24Subtitle: nil,
            isLoadingInstagram: false,
            isLoadingCafe24: false,
            onInstagramAction: {},
            onCafe24Action: {}
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("연결 완료") {
    NavigationStack {
        ConnectedAccountsContent(
            instagramSubtitle: "@dlstnaos",
            cafe24Subtitle: "@dobbyisvintage.cafe24.com",
            isLoadingInstagram: false,
            isLoadingCafe24: false,
            onInstagramAction: {},
            onCafe24Action: {}
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .navigationTitle("연결된 계정 관리")
        .navigationBarTitleDisplayMode(.inline)
    }
}
