import SwiftUI

struct ConnectedAccountsView: View {
    @State private var model = ConnectedAccountsModel()
    @State private var cafe24MallID = ""
    @State private var isEnteringCafe24MallID = false

    var body: some View {
        ConnectedAccountsContent(
            state: contentState,
            onAction: handleAccountAction
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
        .alert("계정 연결 안내", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var contentState: ConnectedAccountsState {
        let instagramState: ConnectedAccountState
        if let account = model.instagramAccount {
            instagramState = .connected(account: "@\(account.username)")
        } else {
            instagramState = .disconnected
        }

        let cafe24State: ConnectedAccountState
        if let mallID = model.cafe24MallID {
            cafe24State = .connected(account: "@\(mallID).cafe24.com")
        } else {
            cafe24State = .disconnected
        }

        return ConnectedAccountsState(
            instagram: ConnectedAccountItem(
                platform: .instagram,
                state: instagramState,
                isWorking: model.isLoading(.instagram)
            ),
            cafe24: ConnectedAccountItem(
                platform: .cafe24,
                state: cafe24State,
                isWorking: model.isLoading(.cafe24)
            )
        )
    }

    private func handleAccountAction(_ platform: ConnectedAccountPlatform) {
        switch platform {
        case .instagram:
            if model.instagramAccount == nil {
                Task { await model.connectInstagram() }
            } else {
                Task { await model.disconnect(.instagram) }
            }
        case .cafe24:
            if model.cafe24MallID == nil {
                isEnteringCafe24MallID = true
            } else {
                Task { await model.disconnect(.cafe24) }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ConnectedAccountsView()
    }
}
