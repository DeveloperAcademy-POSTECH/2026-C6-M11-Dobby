import SwiftUI

private enum Cafe24UploadState {
    case idle
    case uploading
    case completed(Cafe24PublishResult)

    var isUploading: Bool {
        if case .uploading = self { true } else { false }
    }

    var isCompleted: Bool {
        if case .completed = self { true } else { false }
    }
}

struct Cafe24ExportView: View {
    let onPublished: (Cafe24PublishResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = Cafe24IntegrationClient()
    @State private var draft: Cafe24ExportDraft
    @State private var connectedMallID: String?
    @State private var isLoadingConnection = true
    @State private var connectionError: String?
    @State private var uploadState: Cafe24UploadState = .idle
    @State private var isConnecting = false
    @State private var message: String?
    @State private var isConfirmingRepublish = false

    init(product: ExportProduct, onPublished: @escaping (Cafe24PublishResult) -> Void = { _ in }) {
        self.onPublished = onPublished
        _draft = State(initialValue: Cafe24ExportDraft(product: product))
    }

    var body: some View {
        Group {
            if connectedMallID != nil {
                Cafe24ProductView(
                    draft: $draft,
                    isCompleted: uploadState.isCompleted,
                    isDisabled: uploadState.isUploading,
                    onReportProblem: {
                        message = "카페24 관리자에서 상품을 먼저 확인해 주세요. 상품이 없다면 다시 업로드할 수 있습니다."
                    }
                )
            } else {
                Cafe24ConnectionView(
                    isLoading: isConnecting || isLoadingConnection,
                    errorMessage: connectionError,
                    onConnect: { mallID in Task { await connect(mallID: mallID) } },
                    onRefresh: { Task { await loadStatus() } }
                )
            }
        }
        .navigationTitle("카페24로 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            if !uploadState.isUploading {
                ToolbarItem(placement: .topBarLeading) {
                    ExportGlassNavigationButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "플랫폼 업로드로 돌아가기"
                    ) {
                        dismiss()
                    }
                }
            }
            if connectedMallID != nil && !uploadState.isUploading {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportAccountMenu(
                        accessibilityLabel: "카페24 계정 메뉴",
                        onReconnect: { Task { await loadStatus() } },
                        onDisconnect: { Task { await disconnect() } }
                    )
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if connectedMallID != nil {
                ExportBottomActionBar {
                    ExportBottomAction(
                        title: "업로드하기",
                        isWorking: uploadState.isUploading,
                        isEnabled: uploadState.isCompleted || canPublish
                    ) {
                        if uploadState.isCompleted {
                            isConfirmingRepublish = true
                        } else {
                            Task { await publish() }
                        }
                    }
                }
            }
        }
        .overlay {
            if isConnecting {
                ExportLoadingOverlay(message: "카페24와 연결 중…")
            } else if uploadState.isUploading {
                ExportLoadingOverlay(message: "카페24에 상품을 업로드하고 있어요…")
            }
        }
        .interactiveDismissDisabled(uploadState.isUploading)
        .task { await loadStatus() }
        .confirmationDialog("상품을 한 번 더 올릴까요?", isPresented: $isConfirmingRepublish,
                            titleVisibility: .visible) {
            Button("다시 업로드하기") { Task { await publish() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("다시 업로드하면 같은 쇼핑몰에 새 상품이 추가됩니다.")
        }
        .alert("카페24 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var canPublish: Bool {
        !uploadState.isUploading && draft.canPublish
    }

    private func loadStatus() async {
        isLoadingConnection = true
        connectionError = nil
        defer { isLoadingConnection = false }
        do {
            let status = try await client.connectionStatus()
            connectedMallID = status.connected ? status.mallID : nil
        } catch {
            connectedMallID = nil
            connectionError = error.localizedDescription
        }
    }

    private func connect(mallID: String) async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await client.connect(mallID: mallID)
            let status = try await client.connectionStatus()
            connectedMallID = status.connected ? status.mallID : nil
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func publish() async {
        if let validationMessage = draft.validationMessage {
            message = validationMessage
            return
        }
        guard let price = draft.price else { return }
        uploadState = .uploading
        do {
            let result = try await client.publish(
                productName: draft.productName,
                description: draft.productDescription,
                price: price,
                images: draft.photos
            )
            uploadState = .completed(result)
            onPublished(result)
        } catch {
            uploadState = .idle
            message = error.localizedDescription
        }
    }

    private func disconnect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await client.disconnect()
            connectedMallID = nil
            connectionError = nil
            uploadState = .idle
        } catch {
            message = error.localizedDescription
        }
    }
}

#Preview { NavigationStack { Cafe24ExportView(product: .demo) } }
