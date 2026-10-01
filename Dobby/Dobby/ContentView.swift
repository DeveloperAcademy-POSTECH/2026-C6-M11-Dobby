import SwiftUI

struct ContentView: View {
    @State private var showExport = false
    @State private var showCopyRequest = false
    @State private var coordinator = CopyCoordinator()
    @Environment(\.scenePhase) private var phase
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("상품 정보 빠른 복사 · 후르츠 우선") { QuickCopyView() }
                Button("내보내기 채널") { showExport = true }
            }
            .navigationTitle("Dobby")
            .navigationDestination(isPresented: $showCopyRequest) { CopyRequestView(coordinator: coordinator) }
        }
        .sheet(isPresented: $showExport) { ExportView() }
        .onOpenURL { url in
            guard url.scheme == "dobby-copy" else { return }
            showExport = false
            showCopyRequest = true
            if url != CopyRoute.home {
                coordinator.receive(url)
                coordinator.processIfActive(phase)
            }
        }
        .onChange(of: phase) { _, newPhase in coordinator.processIfActive(newPhase) }
    }
}
