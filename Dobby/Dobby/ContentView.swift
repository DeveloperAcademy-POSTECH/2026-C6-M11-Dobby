import SwiftUI

struct ContentView: View {
    private enum RootPresentation {
        case lidar
        case export
    }

    @State private var showLiDAR = false
    @State private var showExport = false
    @State private var showCopyRequest = false
    // Keep this marker until onDismiss, including interactive dismissal.
    // Presentation bindings become false before the dismissal animation ends.
    @State private var activePresentation: RootPresentation?
    @State private var pendingCopyURL: URL?
    @State private var coordinator = CopyCoordinator()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            List {
                Button {
                    present(.lidar)
                } label: {
                    Label("옷 촬영 · 실측", systemImage: "ruler")
                }
                .accessibilityIdentifier("openLiDARLab")
                NavigationLink("상품 정보 빠른 복사 · 후르츠 우선") { QuickCopyView() }
                    .accessibilityIdentifier("openQuickCopy")
                Button("내보내기 채널") { present(.export) }
                    .accessibilityIdentifier("openExportChannels")
            }
            .navigationTitle("Dobby")
            .navigationDestination(isPresented: $showCopyRequest) {
                CopyRequestView(coordinator: coordinator)
            }
        }
        .sheet(isPresented: $showExport, onDismiss: finishPresentation) { ExportView() }
        .fullScreenCover(isPresented: $showLiDAR, onDismiss: finishPresentation) {
            // LiDARLabView owns its own NavigationStack.
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
        .onOpenURL(perform: receiveCopyURL)
        .onChange(of: phase) { _, newPhase in coordinator.processIfActive(newPhase) }
    }

    private func present(_ presentation: RootPresentation) {
        guard activePresentation == nil else { return }
        activePresentation = presentation
        switch presentation {
        case .lidar: showLiDAR = true
        case .export: showExport = true
        }
    }

    private func receiveCopyURL(_ url: URL) {
        guard url.scheme == "dobby-copy" else { return }
        pendingCopyURL = url
        showLiDAR = false
        showExport = false
        openPendingCopyRequest()
    }

    private func finishPresentation() {
        activePresentation = nil
        openPendingCopyRequest()
    }

    private func openPendingCopyRequest() {
        guard activePresentation == nil, let url = pendingCopyURL else { return }
        pendingCopyURL = nil
        let alreadyShowingRequest = showCopyRequest
        showCopyRequest = true
        if url != CopyRoute.home {
            coordinator.receive(url)
            // A new destination processes onAppear. An existing one needs an
            // explicit retry because it will not appear again for this URL.
            if alreadyShowingRequest { coordinator.processIfActive(phase) }
        }
    }
}

#Preview {
    ContentView()
}
