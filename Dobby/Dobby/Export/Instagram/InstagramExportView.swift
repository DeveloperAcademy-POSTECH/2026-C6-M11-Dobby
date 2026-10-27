import SwiftUI

private enum InstagramUploadState {
    case idle
    case uploading
    case completed

    var isUploading: Bool {
        if case .uploading = self { true } else { false }
    }

    var isCompleted: Bool {
        if case .completed = self { true } else { false }
    }
}

struct InstagramExportView: View {
    let product: ExportProduct
    let onPublished: (InstagramPublishResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = InstagramIntegrationClient()
    @State private var account: InstagramAccount?
    @State private var isLoadingAccount = true
    @State private var accountLoadError: String?
    @State private var draft: InstagramExportDraft
    @State private var uploadState: InstagramUploadState = .idle
    @State private var busy = false
    @State private var confirming = false
    @State private var confirmingRepublish = false
    @State private var message: String?
    @State private var requestID = UUID().uuidString

    init(product: ExportProduct, onPublished: @escaping (InstagramPublishResult) -> Void = { _ in }) {
        self.product = product
        self.onPublished = onPublished
        _draft = State(initialValue: InstagramExportDraft(product: product))
    }

    var body: some View {
        Group {
            if let account {
                InstagramComposeView(
                    account: account,
                    draft: $draft,
                    isDisabled: busy || uploadState.isCompleted,
                    isCompleted: uploadState.isCompleted,
                    onReportProblem: { message = "Instagram 앱에서 게시물을 먼저 확인해 주세요. 게시물이 없다면 다시 업로드할 수 있습니다." }
                )
            } else {
                InstagramConnectionView(
                    isLoading: busy || isLoadingAccount,
                    errorMessage: accountLoadError,
                    onConnect: { Task { await connect() } }
                )
            }
        }
        .navigationTitle("인스타그램으로 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            if !uploadState.isUploading {
                ToolbarItem(placement: .topBarLeading) {
                    ExportNavigationButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "플랫폼 업로드로 돌아가기"
                    ) {
                        dismiss()
                    }
                }
            }
            if account != nil && !uploadState.isUploading {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportAccountMenu(
                        accessibilityLabel: "Instagram 계정 메뉴",
                        onReconnect: { Task { await connect() } },
                        onDisconnect: { Task { await disconnect() } }
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if account != nil {
                ExportBottomActionBar {
                    ExportBottomAction(
                        title: "업로드하기",
                        isWorking: uploadState.isUploading,
                        isComplete: false,
                        isEnabled: uploadState.isCompleted || canPublish
                    ) {
                        if uploadState.isCompleted {
                            confirmingRepublish = true
                        } else {
                            confirming = true
                        }
                    }
                }
            }
        }
        .overlay {
            if uploadState.isUploading {
                PlatformUploadingOverlay(platformName: "인스타그램")
                    .zIndex(10)
            }
        }
        .interactiveDismissDisabled(uploadState.isUploading)
        .task { await loadAccount() }
        .confirmationDialog("@\(account?.username ?? "")에 실제로 게시할까요?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("공개 게시하기") { Task { await publish() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 사진과 내용이 Instagram에 공개됩니다.")
        }
        .confirmationDialog("게시물을 한 번 더 올릴까요?", isPresented: $confirmingRepublish,
                            titleVisibility: .visible) {
            Button("다시 업로드하기") { Task { await republish() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("다시 업로드하면 같은 계정에 새 게시물이 추가됩니다.")
        }
        .alert("Instagram 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var canPublish: Bool {
        !busy && !uploadState.isUploading && account != nil && draft.canPublish
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
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.disconnect()
            account = nil
            requestID = UUID().uuidString
            uploadState = .idle
        } catch {
            message = error.localizedDescription
        }
    }

    private func publish() async {
        guard let expected = account else { return }
        uploadState = .uploading
        do {
            let current = try await client.account()
            guard current?.id == expected.id else {
                account = current
                uploadState = .idle
                message = "연결 계정이 변경되었습니다. 게시할 계정을 다시 확인해 주세요."
                return
            }
            let result = try await client.publish(images: draft.photos.map(\.data), caption: draft.caption,
                                                  accountID: expected.id, requestID: requestID)
            uploadState = .completed
            onPublished(result)
        } catch {
            uploadState = .idle
            message = error.localizedDescription
        }
    }

    private func republish() async {
        requestID = UUID().uuidString
        await publish()
    }
}
