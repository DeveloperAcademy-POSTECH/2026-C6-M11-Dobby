import SwiftData
import SwiftUI

struct ExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    @Binding var showFruits: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var completedChannels: Set<ExportChannel>
    @State private var selectionSaveError: String?
    @State private var showCafe24 = false
    @State private var showInstagram = false
    @State private var showFruitsGuideOverlay = false

    init(product: ExportProduct, controller: CopyActivityController, showFruits: Binding<Bool>) {
        self.product = product
        self.controller = controller
        _showFruits = showFruits
        _completedChannels = State(initialValue: product.completedChannels)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ExportProductItem(product: product)
                    ExportChannelListView(completedChannels: completedChannels,
                                          onSelectChannel: didSelectChannel)
                }.padding(.horizontal, 33).padding(.bottom, 32)
            }
            .background(Color(.brandNeutral50))
            .navigationTitle("플랫폼 업로드하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ExportGlassNavigationButton(systemImage: "xmark", accessibilityLabel: "닫기") {
                        dismiss()
                    }
                    .accessibilityIdentifier("export.close")
                }
            }
            .navigationDestination(isPresented: $showFruits) {
                FruitsExportView(product: product, controller: controller) {
                    completedChannels.insert(.fruitsFamily)
                }
            }
            .navigationDestination(isPresented: $showCafe24) {
                Cafe24ExportView(product: product) { _ in
                    completedChannels.insert(.cafe24)
                    try? ExportCompletionRecorder.record(productID: product.id, channel: .cafe24,
                                                         in: modelContext)
                }
            }
            .navigationDestination(isPresented: $showInstagram) {
                InstagramExportView(product: product) { _ in
                    completedChannels.insert(.instagram)
                    try? ExportCompletionRecorder.record(productID: product.id, channel: .instagram,
                                                         in: modelContext)
                }
            }
            .disabled(controller.busy)
        }
        .overlay {
            if showFruitsGuideOverlay {
                FruitsExportGuideOverlay(
                    product: product,
                    controller: controller,
                    onDismiss: { showFruitsGuideOverlay = false },
                    onOpened: {
                        completedChannels.insert(.fruitsFamily)
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFruitsGuideOverlay)
        .alert("플랫폼 기록을 저장하지 못했어요", isPresented: Binding(
            get: { selectionSaveError != nil },
            set: { if !$0 { selectionSaveError = nil } }
        )) {
            Button("확인", role: .cancel) { selectionSaveError = nil }
        } message: {
            Text(selectionSaveError ?? "다시 시도해 주세요.")
        }
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        guard !controller.busy, recordSelection(channel) else { return }
        switch channel {
        case .instagram:
            showInstagram = true
        case .cafe24:
            showCafe24 = true
        case .fruitsFamily:
            showFruitsGuideOverlay = true
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

#Preview {
    ExportView(product: .demo, controller: CopyActivityController(), showFruits: .constant(false))
}
