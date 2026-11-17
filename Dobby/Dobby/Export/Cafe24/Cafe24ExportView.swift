import SwiftUI
import UIKit

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
    private static let navigationTitle = "카페24로 업로드하기"

    let onRequestExit: (ExportReturnDestination) -> Void
    let onPublished: (Cafe24PublishResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var client = Cafe24IntegrationClient()
    @State private var draft: Cafe24ExportDraft
    @State private var connectedMallID: String?
    @State private var showsConnectionCompletion = false
    @State private var isLoadingConnection = true
    @State private var connectionError: String?
    @State private var uploadState: Cafe24UploadState = .idle
    @State private var isConnecting = false
    @State private var isDisconnecting = false
    @State private var message: String?
    @State private var uploadRequestID = UUID()

    init(
        product: ExportProduct,
        onRequestExit: @escaping (ExportReturnDestination) -> Void = { _ in },
        onPublished: @escaping (Cafe24PublishResult) -> Void = { _ in }
    ) {
        self.onRequestExit = onRequestExit
        self.onPublished = onPublished
        _draft = State(initialValue: Cafe24ExportDraft(product: product))
    }

    var body: some View {
        Group {
            if case .completed(let result) = uploadState {
                Cafe24UploadCompletionView(
                    mallID: result.mallID,
                    onOpenLibrary: { onRequestExit(.library) }
                )
            } else if showsConnectionCompletion {
                Cafe24ConnectionCompletionView(
                    onOpenLibrary: { onRequestExit(.library) },
                    onContinueToUpload: { showsConnectionCompletion = false }
                )
            } else if let connectedMallID {
                Cafe24ProductView(
                    draft: $draft,
                    mallID: connectedMallID,
                    isDisabled: uploadState.isUploading
                )
            } else {
                Cafe24ConnectionView(
                    isLoading: isConnecting || isLoadingConnection,
                    errorMessage: connectionError,
                    onConnect: { mallID in Task { await connect(mallID: mallID) } }
                )
            }
        }
        .accessibilityHidden(uploadState.isUploading)
        .navigationTitle(Self.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(showsCompletion ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ExportToolbarTitle(title: Self.navigationTitle)
                    .accessibilityHidden(uploadState.isUploading)
            }
            if !uploadState.isUploading && !showsCompletion {
                ToolbarItem(placement: .topBarLeading) {
                    ExportNavigationButton(
                        systemImage: "chevron.left",
                        accessibilityLabel: "플랫폼 업로드로 돌아가기"
                    ) {
                        dismiss()
                    }
                }
            }
            if connectedMallID != nil && !uploadState.isUploading && !isDisconnecting && !showsCompletion {
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
            if connectedMallID != nil && !showsCompletion {
                ExportBottomActionBar {
                    ExportBottomAction(title: "업로드하기") {
                        dismissKeyboard()
                        Task { await publish() }
                    }
                }
                .accessibilityHidden(uploadState.isUploading)
            }
        }
        .overlay {
            if uploadState.isUploading {
                PlatformUploadingOverlay(platformName: "카페24")
            }
        }
        .interactiveDismissDisabled(uploadState.isUploading)
        .task { await loadStatus() }
        .alert("카페24 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
    }

    private var showsCompletion: Bool {
        showsConnectionCompletion || uploadState.isCompleted
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
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
            showsConnectionCompletion = connectedMallID != nil
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func publish() async {
        guard !isConnecting, !isDisconnecting, !uploadState.isUploading else { return }
        if let validationMessage = draft.validationMessage {
            message = validationMessage
            return
        }
        guard let price = draft.price else { return }
        uploadState = .uploading
        do {
            let result = try await client.publish(
                requestID: uploadRequestID.uuidString,
                productName: draft.productName,
                description: draft.productDescription,
                category: draft.category,
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
        guard !isConnecting, !isDisconnecting else { return }
        isDisconnecting = true
        defer { isDisconnecting = false }
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

private struct Cafe24UploadCompletionView: View {
    let mallID: String
    let onOpenLibrary: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        ExportCompletionContent(
            icon: .uploadCompletionIcon,
            title: "업로드 완료",
            message: "연결된 계정에 자동으로 업로드했어요!",
            secondary: .init(
                title: "보관함으로 가기",
                accessibilityIdentifier: "export.cafe24.library",
                action: onOpenLibrary
            ),
            primary: .init(
                title: "카페24 열기",
                accessibilityIdentifier: "export.cafe24.open",
                action: openStorefront
            )
        )
    }

    private func openStorefront() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(mallID).cafe24.com"
        guard let url = components.url else { return }
        openURL(url)
    }
}

private struct Cafe24ConnectionCompletionView: View {
    let onOpenLibrary: () -> Void
    let onContinueToUpload: () -> Void

    var body: some View {
        ExportCompletionContent(
            icon: .instagramConnectionCompletionIcon,
            title: "카페24 연결 완료!",
            message: "카페24 계정과\n성공적으로 연결을 완료했어요",
            secondary: .init(
                title: "보관함으로 가기",
                accessibilityIdentifier: "export.cafe24.library",
                action: onOpenLibrary
            ),
            primary: .init(
                title: "업로드하러 가기",
                accessibilityIdentifier: "export.cafe24.continueToUpload",
                action: onContinueToUpload
            ),
            primaryFontSize: 17
        )
    }
}

#Preview { NavigationStack { Cafe24ExportView(product: .demo) } }

#Preview("카페24 업로드 완료") {
    Cafe24UploadCompletionView(mallID: "dobbyisvintage", onOpenLibrary: {})
}

#Preview("카페24 연결 완료") {
    Cafe24ConnectionCompletionView(onOpenLibrary: {}, onContinueToUpload: {})
}
