import SwiftUI

struct ContentView: View {
    @State private var showExport = false
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("상품 정보 빠른 복사 · 후르츠 우선") { QuickCopyView() }
                Button("내보내기 채널") { showExport = true }
            }
            .navigationTitle("Dobby")
        }
        .sheet(isPresented: $showExport) { ExportView() }
    }
}
