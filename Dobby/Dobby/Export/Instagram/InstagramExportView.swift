import SwiftUI

struct InstagramExportView: View {
    let product: ExportProduct
    @State private var client = InstagramIntegrationClient()
    @State private var account: InstagramAccount?
    @State private var isLoadingAccount = true
    @State private var accountLoadError: String?
    @State private var draft: InstagramExportDraft
    @State private var busy = false
    @State private var confirming = false
    @State private var message: String?
    @State private var published = false
    @State private var confirmingDisconnect = false
    @State private var requestID = UUID().uuidString

    init(product: ExportProduct) {
        self.product = product
        _draft = State(initialValue: InstagramExportDraft(product: product))
    }

    var body: some View {
        Group {
            if let account {
                InstagramComposeView(account: account, draft: $draft, isDisabled: busy || published)
            } else {
                InstagramConnectionView(
                    isLoading: busy || isLoadingAccount,
                    errorMessage: accountLoadError,
                    onConnect: { Task { await connect() } },
                    onRefresh: { Task { await loadAccount() } }
                )
            }
        }
        .navigationTitle("인스타그램으로 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("계정 새로고침", systemImage: "arrow.clockwise") {
                            Task { await loadAccount() }
                        }
                        Button("연결 해제", systemImage: "link.badge.minus", role: .destructive) {
                            confirmingDisconnect = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Instagram 계정 메뉴")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if account != nil {
                ExportBottomActionBar {
                    ExportBottomAction(
                        title: published ? "게시 완료" : "업로드하기",
                        isWorking: busy,
                        isComplete: published,
                        isEnabled: canPublish
                    ) {
                        confirming = true
                    }
                }
            }
        }
        .task { await loadAccount() }
        .confirmationDialog("Instagram 연결을 해제할까요?", isPresented: $confirmingDisconnect,
                            titleVisibility: .visible) {
            Button("연결 해제", role: .destructive) { Task { await disconnect() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 기기의 연결 정보가 서버에서 삭제됩니다. 기존 Instagram 게시물은 유지됩니다.")
        }
        .confirmationDialog("@\(account?.username ?? "")에 실제로 게시할까요?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("공개 게시하기") { Task { await publish() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 사진과 내용이 Instagram에 공개됩니다.")
        }
        .alert(published ? "게시 완료" : "Instagram 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var canPublish: Bool {
        !busy && !published && account != nil && !draft.photos.isEmpty
            && !draft.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.caption.utf16.count <= 2200
    }

    private func loadAccount() async {
        isLoadingAccount = true
        accountLoadError = nil
        defer { isLoadingAccount = false }
        do { account = try await client.account() }
        catch { account = nil; accountLoadError = error.localizedDescription }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do {
            account = try await client.connect()
            accountLoadError = nil
            requestID = UUID().uuidString
        } catch {
            accountLoadError = error.localizedDescription
        }
    }

    private func disconnect() async {
        busy = true
        defer { busy = false }
        do {
            try await client.disconnect()
            account = nil
            requestID = UUID().uuidString
        } catch {
            message = error.localizedDescription
        }
    }

    private func publish() async {
        guard let expected = account else { return }
        busy = true
        defer { busy = false }
        do {
            let current = try await client.account()
            guard current?.id == expected.id else {
                account = current
                message = "연결 계정이 변경되었습니다. 게시할 계정을 다시 확인해 주세요."
                return
            }
            let result = try await client.publish(images: draft.photos.map(\.data), caption: draft.caption,
                                                  accountID: expected.id, requestID: requestID)
            published = true
            message = "@\(result.username)에 게시했습니다.\n게시물 ID: \(result.mediaID)"
        } catch {
            message = error.localizedDescription
        }
    }
}
