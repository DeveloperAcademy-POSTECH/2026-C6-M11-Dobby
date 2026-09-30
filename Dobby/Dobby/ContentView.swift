import SwiftUI

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
            guard url.scheme == "dobby-copy", url.host == "home" else { return }
            controller.refresh()
            if let session = controller.session, session.productID != product.id {
                restoredProduct = ExportProduct(id: session.productID, imageData: nil,
                                                fruits: session.payload, instagram: session.payload)
            } else { restoredProduct = nil }
            showFruits = true
            showExport = true
        }
    }
}
