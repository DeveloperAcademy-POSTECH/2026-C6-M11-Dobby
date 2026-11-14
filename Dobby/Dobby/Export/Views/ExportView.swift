import SwiftData
import SwiftUI

struct ExportView: View {
    private static let navigationTitle = "플랫폼 업로드하기"

    let product: ExportProduct
    private let onRequestExit: ((ExportReturnDestination) throws -> Void)?
    @Binding var showFruits: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var completedChannels: Set<ExportChannel>
    @State private var selectionSaveError: String?
    @State private var closeError: String?
    @State private var showCafe24 = false
    @State private var showInstagram = false

    init(product: ExportProduct, showFruits: Binding<Bool>,
         onRequestExit: ((ExportReturnDestination) throws -> Void)? = nil) {
        self.product = product
        self.onRequestExit = onRequestExit
        _showFruits = showFruits
        _completedChannels = State(initialValue: product.completedChannels)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ExportContentView(product: product, completedChannels: completedChannels,
                                  onSelectChannel: didSelectChannel)
            }
            .background(Color(.brandNeutralWhite))
            .navigationTitle(Self.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ExportToolbarTitle(title: Self.navigationTitle)
                }
                ToolbarItem(placement: .topBarLeading) {
                    ExportNavigationButton(
                        systemImage: "xmark",
                        accessibilityLabel: "홈으로 이동",
                        action: requestHomeExit
                    )
                    .accessibilityIdentifier("export.close")
                }
            }
            .navigationDestination(isPresented: $showFruits) {
                FruitsExportView(product: product) {
                    completedChannels.insert(.fruitsFamily)
                }
            }
            .navigationDestination(isPresented: $showCafe24) {
                Cafe24ExportView(product: product, onRequestExit: requestExit) { _ in
                    completedChannels.insert(.cafe24)
                    try? ExportCompletionRecorder.record(productID: product.id, channel: .cafe24,
                                                         in: modelContext)
                }
            }
            .navigationDestination(isPresented: $showInstagram) {
                InstagramExportView(product: product, onRequestExit: requestExit) { _ in
                    completedChannels.insert(.instagram)
                    try? ExportCompletionRecorder.record(productID: product.id, channel: .instagram,
                                                         in: modelContext)
                }
            }
        }
        .toast(bottomPadding: 112)
        .alert("플랫폼 기록을 저장하지 못했어요", isPresented: Binding(
            get: { selectionSaveError != nil },
            set: { if !$0 { selectionSaveError = nil } }
        )) {
            Button("확인", role: .cancel) { selectionSaveError = nil }
        } message: {
            Text(selectionSaveError ?? "다시 시도해 주세요.")
        }
        .alert("작업을 저장하지 못했어요", isPresented: Binding(
            get: { closeError != nil }, set: { if !$0 { closeError = nil } }
        )) {
            Button("확인", role: .cancel) { closeError = nil }
        } message: {
            Text(closeError ?? "진행 중인 작업은 화면에 남아 있어요.")
        }
    }

    private func requestHomeExit() {
        requestExit(to: .home)
    }

    private func requestExit(to destination: ExportReturnDestination) {
        closeError = nil
        do {
            if let onRequestExit { try onRequestExit(destination) }
            else { dismiss() }
        } catch {
            closeError = "진행 중인 작업을 저장하지 못해 홈으로 이동하지 못했어요. 내용은 화면에 남아 있어요. 확인 후 닫기 버튼을 다시 눌러 주세요.\n\(error.localizedDescription)"
        }
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        guard recordSelection(channel) else { return }
        switch channel {
        case .instagram:
            showInstagram = true
        case .cafe24:
            showCafe24 = true
        case .fruitsFamily:
            showFruits = true
        case .naverStore:
            break
        }
    }

    private func recordSelection(_ channel: ExportChannel) -> Bool {
        do {
            try GarmentStore.recordSelectedExportChannel(channel, productID: product.id, in: modelContext)
            return true
        } catch {
            selectionSaveError = "플랫폼 선택 기록을 저장하지 못했어요. 잠시 후 다시 시도해 주세요."
            return false
        }
    }
}

private struct ExportContentView: View {
    let product: ExportProduct
    let completedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(spacing: 24) {
            ExportProductItem(product: product)
            ExportChannelListView(completedChannels: completedChannels,
                                  onSelectChannel: onSelectChannel)
        }
        .frame(maxWidth: 337)
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ExportView(product: .demo, showFruits: .constant(false))
}

#Preview("플랫폼 업로드 · 본문", traits: .sizeThatFitsLayout) {
    ExportContentView(
        product: .demo,
        completedChannels: [.instagram],
        onSelectChannel: { _ in }
    )
    .frame(width: 402)
    .background(Color(.brandNeutralWhite))
}
