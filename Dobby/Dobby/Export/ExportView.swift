import SwiftUI

struct ExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    @Binding var showFruits: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var history = ExportHistoryStore()
    @State private var isShowingOpenError = false
    @State private var isOpeningLink = false
    @State private var showFruitsGuideA = false
    @State private var showCafe24 = false
    @State private var showNaverStore = false
    @State private var showInstagram = false
    @State private var showFruitsGuideOverlay = false
    @State private var openedFruitsMethods: Set<FruitsExportMethod> = []

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
            .navigationDestination(isPresented: $showNaverStore) {
                NaverStoreExportView(product: product)
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
    }

    private func selectFruits(_ method: FruitsExportMethod) {
        guard !controller.busy, !isOpeningLink else { return }
        if method == .dynamicIslandB {
            showFruitsGuideOverlay = true
        } else {
            showFruitsGuideA = true
        }
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        if channel == .instagram { showInstagram = true; return }
        if channel == .fruitsFamily { showFruits = true; return }
        if channel == .cafe24 { showCafe24 = true; return }
        if channel == .naverStore { showNaverStore = true; return }
        guard !isOpeningLink else { return }
        isOpeningLink = true
        openURL(channel.destinationURL) { accepted in
            history.recordOpenResult(for: channel, accepted: accepted)
            isOpeningLink = false
            isShowingOpenError = !accepted
        }
    }
}

#Preview {
    ExportView(product: .demo, controller: CopyActivityController(), showFruits: .constant(false))
}
