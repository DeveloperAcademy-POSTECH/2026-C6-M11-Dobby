import SwiftUI

struct ContentView: View {
    @State private var isShowingExport = false

    var body: some View {
        Button("내보내기") {
            isShowingExport = true
        }
        .buttonStyle(.borderedProminent)
        .sheet(isPresented: $isShowingExport) {
            ExportView()
        }
    }
}

#Preview {
    ContentView()
}
