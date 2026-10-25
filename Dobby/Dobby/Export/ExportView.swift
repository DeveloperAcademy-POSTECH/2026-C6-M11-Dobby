import SwiftData
import SwiftUI

struct ExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    @Binding var showFruits: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var completedChannels: Set<ExportChannel>
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
                    ExportProductHeader(product: product)
                    ExportChannelListView(completedChannels: completedChannels,
                                          onSelectChannel: didSelectChannel)
                }.padding(.horizontal, 33).padding(.bottom, 32)
            }
            .background(Color(.brandNeutral50))
            .navigationTitle("플랫폼 업로드하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.primary) }
                        .accessibilityLabel("닫기").accessibilityIdentifier("export.close")
                }
            }
            .navigationDestination(isPresented: $showFruits) {
                FruitsExportView(product: product, controller: controller) {
                    completedChannels.insert(.fruitsFamily)
                }
            }
            .navigationDestination(isPresented: $showCafe24) {
                Cafe24ExportView(product: product)
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
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        if channel == .instagram { showInstagram = true; return }
        if channel == .fruitsFamily { showFruitsGuideOverlay = true; return }
        if channel == .cafe24 { showCafe24 = true; return }
    }
}

#Preview {
    ExportView(product: .demo, controller: CopyActivityController(), showFruits: .constant(false))
}
