import SwiftUI
import UIKit

struct ContentView: View {
    let product: ExportProduct
    @State private var showLiDAR = false
    @State private var showExport = false
    @State private var showFruits = false
    @State private var restoredProduct: ExportProduct?
    @State private var controller = CopyActivityController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Button {
                    showLiDAR = true
                } label: {
                    Label("옷 촬영 · 실측", systemImage: "ruler")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("openLiDARLab")

                ExportProductHeader(product: product)
                Button("내보내기") {
                    restoredProduct = nil
                    showFruits = false
                    showExport = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("openExportChannels")
            }
            .padding()
            .navigationTitle("상품 정보")
        }
        .fullScreenCover(isPresented: $showLiDAR) {
            LiDARLabView()
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Spacer()
                        Button("닫기") { showLiDAR = false }
                            .font(.body.weight(.semibold))
                            .accessibilityIdentifier("closeLiDARLab")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
        }
        .fullScreenCover(isPresented: $showExport) {
            ExportView(product: restoredProduct ?? product, controller: controller, showFruits: $showFruits)
        }
        .onOpenURL { url in
            if ForegroundCopyRelay.canHandle(url) {
                let result = ForegroundCopyRelay.handle(url)
                guard result.copied, let destination = result.destination else { return }
                Task { @MainActor in
                    if let field = result.field {
                        controller.refresh()
                        await controller.markCopied(field)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    _ = await UIApplication.shared.open(
                        destination,
                        options: [.universalLinksOnly: true]
                    )
                }
                return
            }
            guard url.scheme == "dobby-copy", url.host == "home" else { return }
            controller.refresh()
            if let session = controller.session {
                // 같은 상품 ID라도 편집된 본문과 활동의 스냅샷은 다를 수 있다.
                restoredProduct = ExportProduct(
                    id: session.productID,
                    imageData: session.productID == product.id ? product.imageData : nil,
                    fruits: session.payload,
                    instagram: session.productID == product.id ? product.instagram : session.payload,
                    detailMeasurements: session.measurementItems?.map {
                        ExportMeasurement(id: $0.id, title: $0.title, value: $0.value)
                    }
                )
            } else {
                restoredProduct = nil
            }
            showFruits = true
            showExport = true
        }
    }
}

#Preview {
    ContentView(product: .demo)
}
