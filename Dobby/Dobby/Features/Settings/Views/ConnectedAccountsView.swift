import SwiftUI

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
                actionState: model.instagramAccount == nil ? .connect : .disconnect,
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
                actionState: model.cafe24MallID == nil ? .connect : .disconnect,
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
        .background(SettingsStyle.surface)
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
