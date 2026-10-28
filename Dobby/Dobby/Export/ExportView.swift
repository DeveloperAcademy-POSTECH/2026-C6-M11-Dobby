import SwiftUI
import SwiftData

struct ExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    @Binding var showFruits: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var modelContext
    @State private var history = ExportHistoryStore()
    @State private var isShowingOpenError = false
    @State private var isOpeningLink = false
    @State private var showFruitsGuideA = false
    @State private var showCafe24 = false
    @State private var showInstagram = false
    @State private var showFruitsGuideOverlay = false
    @State private var openedFruitsMethods: Set<FruitsExportMethod> = []
    @State private var selectionSaveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ExportProductHeader(product: product)
                    ExportChannelListView(openedChannels: history.openedChannels,
                                          onSelectChannel: didSelectChannel,
                                          openedFruitsMethods: openedFruitsMethods,
                                          onSelectFruits: selectFruits)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            .navigationTitle("내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.primary) }
                        .accessibilityLabel("닫기").accessibilityIdentifier("export.close")
                }
            }
            .navigationDestination(isPresented: $showFruits) {
                FruitsExportView(product: product, controller: controller) {
                    openedFruitsMethods.insert(.dynamicIslandB)
                    history.recordOpenResult(for: .fruitsFamily, accepted: true)
                }
            }
            .navigationDestination(isPresented: $showFruitsGuideA) {
                FruitsExportView(product: product, controller: controller) {
                    openedFruitsMethods.insert(.dynamicIslandA)
                    history.recordOpenResult(for: .fruitsFamily, accepted: true)
                }
            }
            .navigationDestination(isPresented: $showCafe24) {
                Cafe24ExportView(product: product)
            }
            .navigationDestination(isPresented: $showInstagram) {
                InstagramExportView(product: product)
            }
            .disabled(isOpeningLink || controller.busy)
            .alert("페이지를 열 수 없습니다", isPresented: $isShowingOpenError) {
                Button("확인", role: .cancel) {}
            } message: { Text("잠시 후 다시 시도해 주세요.") }
        }
        .overlay {
            if showFruitsGuideOverlay {
                FruitsExportGuideOverlay(
                    product: product,
                    controller: controller,
                    onDismiss: { showFruitsGuideOverlay = false },
                    onOpened: {
                        openedFruitsMethods.insert(.dynamicIslandB)
                        history.recordOpenResult(for: .fruitsFamily, accepted: true)
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

    private func selectFruits(_ method: FruitsExportMethod) {
        guard !controller.busy, !isOpeningLink, recordSelection(.fruitsFamily) else { return }
        if method == .dynamicIslandB {
            showFruitsGuideOverlay = true
        } else {
            showFruitsGuideA = true
        }
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        guard !controller.busy, !isOpeningLink, recordSelection(channel) else { return }
        if channel == .instagram { showInstagram = true; return }
        if channel == .fruitsFamily { showFruits = true; return }
        if channel == .cafe24 { showCafe24 = true; return }
        guard !isOpeningLink else { return }
        isOpeningLink = true
        openURL(channel.destinationURL) { accepted in
            history.recordOpenResult(for: channel, accepted: accepted)
            isOpeningLink = false
            isShowingOpenError = !accepted
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
