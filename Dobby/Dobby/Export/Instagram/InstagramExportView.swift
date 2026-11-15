import SwiftUI
import UIKit

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
    private static let navigationTitle = "인스타그램에 업로드하기"

    let product: ExportProduct
    let onRequestExit: (ExportReturnDestination) -> Void
    let onPublished: (InstagramPublishResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = InstagramIntegrationClient()
    @State private var account: InstagramAccount?
    @State private var isLoadingAccount = true
    @State private var accountLoadError: String?
    @State private var showsConnectionCompletion = false
    @State private var draft: InstagramExportDraft
    @State private var uploadState: InstagramUploadState = .idle
    @State private var busy = false
    @State private var isShowingUploadFailure = false
    @State private var message: String?
    @State private var requestID = UUID().uuidString

    init(product: ExportProduct, initialAccount: InstagramAccount? = nil,
         onRequestExit: @escaping (ExportReturnDestination) -> Void,
         onPublished: @escaping (InstagramPublishResult) -> Void = { _ in }) {
        self.product = product
        self.onRequestExit = onRequestExit
        self.onPublished = onPublished
        _account = State(initialValue: initialAccount)
        _isLoadingAccount = State(initialValue: initialAccount == nil)
        _draft = State(initialValue: InstagramExportDraft(product: product))
    }

    var body: some View {
        Group {
            if uploadState.isCompleted {
                InstagramUploadCompletionView(
                    onOpenLibrary: requestLibraryExit,
                    onOpenInstagram: openInstagram
                )
            } else if showsConnectionCompletion {
                InstagramConnectionCompletionView(
                    onOpenLibrary: requestLibraryExit,
                    onContinueToUpload: { showsConnectionCompletion = false }
                )
            } else if let account {
                InstagramComposeView(
                    account: account,
                    draft: $draft,
                    isDisabled: busy
                )
            } else {
                InstagramConnectionView(
                    isLoading: busy || isLoadingAccount,
                    errorMessage: accountLoadError,
                    onConnect: { Task { await connect() } }
                )
            }
        }
        .navigationTitle(Self.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(showsCompletion ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ExportToolbarTitle(title: Self.navigationTitle)
            }
            if !uploadState.isUploading && !showsCompletion {
                ToolbarItem(placement: .topBarLeading) {
                    ExportNavigationButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "플랫폼 업로드로 돌아가기"
                    ) {
                        dismiss()
                    }
                    .buttonBorderShape(.circle)
                }
            }
            if account != nil && !uploadState.isUploading && !showsCompletion {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportAccountMenu(
                        accessibilityLabel: "Instagram 계정 메뉴",
                        onReconnect: { Task { await connect() } },
                        onDisconnect: { Task { await disconnect() } }
                    )
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if account != nil && !showsCompletion {
                ExportBottomAction(title: "업로드하기") {
                    Task { await publish() }
                }
                .padding(.horizontal, 33)
                .padding(.top, 16)
                .background(Color(.brandNeutralWhite))
            }
        }
        .overlay {
            if uploadState.isUploading {
                PlatformUploadingOverlay(platformName: "인스타그램")
                    .zIndex(10)
            } else if isShowingUploadFailure {
                InstagramUploadFailureOverlay(
                    onCancel: { isShowingUploadFailure = false },
                    onRetry: {
                        isShowingUploadFailure = false
                        Task { await republish() }
                    }
                )
                .zIndex(10)
            }
        }
        .interactiveDismissDisabled(uploadState.isUploading)
        .task {
            guard account == nil else { return }
            await loadAccount()
        }
        .alert("Instagram 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var showsCompletion: Bool {
        showsConnectionCompletion || uploadState.isCompleted
    }

    private func requestLibraryExit() {
        onRequestExit(.library)
    }

    private func openInstagram() {
        Task { await openInstagramDestination() }
    }

    private func openInstagramDestination() async {
        let destination = ExportChannel.instagram.destinationURL
        let didOpenApp = await UIApplication.shared.open(
            destination,
            options: [.universalLinksOnly: true]
        )
        guard !didOpenApp else { return }
        await UIApplication.shared.open(destination)
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
            showsConnectionCompletion = true
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
        guard !busy, !uploadState.isUploading else { return }
        if let validationMessage = draft.validationMessage {
            message = validationMessage
            return
        }
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
            isShowingUploadFailure = true
        }
    }

    private func republish() async {
        requestID = UUID().uuidString
        await publish()
    }
}

#Preview("계정 연결 후 · 업로드 화면") {
    NavigationStack {
        InstagramExportView(
            product: .instagramPreview,
            initialAccount: .preview,
            onRequestExit: { _ in }
        )
    }
}
