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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ExportProductHeader(product: product)
                    ExportChannelListView(openedChannels: history.openedChannels, onSelectChannel: didSelectChannel)
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
                    history.recordOpenResult(for: .fruitsFamily, accepted: true)
                }
            }
            .disabled(isOpeningLink)
            .alert("페이지를 열 수 없습니다", isPresented: $isShowingOpenError) {
                Button("확인", role: .cancel) {}
            } message: { Text("잠시 후 다시 시도해 주세요.") }
        }
    }

    private func didSelectChannel(_ channel: ExportChannel) {
        if channel == .fruitsFamily { showFruits = true; return }
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
