import SwiftUI
import UIKit

struct ContentView: View {
    let product: ExportProduct
    @State private var showExport = false
    @State private var showFruits = false
    @State private var restoredProduct: ExportProduct?
    @State private var controller = CopyActivityController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ExportProductHeader(product: product)
                Button("내보내기") {
                    restoredProduct = nil
                    showFruits = false
                    showExport = true
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding()
            .navigationTitle("상품 정보")
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
                restoredProduct = ExportProduct(id: session.productID,
                                                imageData: session.productID == product.id ? product.imageData : nil,
                                                fruits: session.payload,
                                                instagram: session.productID == product.id ? product.instagram : session.payload)
            } else { restoredProduct = nil }
            showFruits = true
            showExport = true
        }
    }
}
