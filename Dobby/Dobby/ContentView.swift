import SwiftUI

struct ContentView: View {
    let product: ExportProduct
    @State private var showExport = false
    @State private var showFruits = false
    @State private var restoredProduct: ExportProduct?
    @State private var controller = CopyActivityController()
    @State private var legacyCopyBridge = LegacyCopyBridge()
    @Environment(\.scenePhase) private var scenePhase

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
            if url.scheme == "dobby-copy", url.host == "copy" {
                legacyCopyBridge.receive(url)
                legacyCopyBridge.processIfActive(scenePhase)
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
        .onChange(of: scenePhase) { _, phase in
            legacyCopyBridge.processIfActive(phase)
        }
    }
}
