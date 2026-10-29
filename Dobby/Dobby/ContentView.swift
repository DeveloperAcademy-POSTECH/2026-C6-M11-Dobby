import SwiftUI
import SwiftData
import UIKit
import ImageIO

struct ContentView: View {
    private enum HomeTab: Hashable { case capture, library, settings }
    private struct CreationRequest: Identifiable {
        let id = UUID()
        let productID: UUID?
    }
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.updatedAt, order: .reverse) private var garments: [Garment]
    @State private var tab: HomeTab = .capture
    @State private var libraryPath: [UUID] = []
    @State private var libraryIsEditing = false
    @State private var creationRequest: CreationRequest?
    @State private var creationCopyHomeProduct: ExportProduct?
    @State private var showLiDAR = false
    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false
    @State private var controller = CopyActivityController()
    @State private var linkError: String?
    @State private var routeTask: Task<Void, Never>?

#if DEBUG
    init(previewLibrary: Bool = false, previewEditing: Bool = false) {
        _tab = State(initialValue: previewLibrary ? .library : .capture)
        _libraryIsEditing = State(initialValue: previewEditing)
    }
#endif

    var body: some View {
        TabView(selection: $tab) {
            Tab("홈", systemImage: libraryIsEditing ? "house" : "house.fill", value: HomeTab.capture) {
                HomeView(resumeCandidate: HomeResumeCandidate.latest(in: garments),
                    onResumeDraft: { startCreation(resuming: $0) },
                    onStartCapture: { startCreation() })
#if DEBUG
                    .overlay(alignment: .bottomTrailing) {
                        if ProcessInfo.processInfo.arguments.contains("--show-measurement-lab") {
                            Button("측정 실험실") { showLiDAR = true }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.trailing, 20)
                                .padding(.bottom, 12)
                                .accessibilityIdentifier("openLiDARLab")
                        }
                    }
#endif
            }
            Tab("보관함", systemImage: "hanger", value: HomeTab.library) {
                NavigationStack(path: $libraryPath) {
                    ProductLibraryView(garments: garments, isEditing: $libraryIsEditing,
                        onStartMeasurement: { startCreation() },
                        onResumeDraft: { startCreation(resuming: $0) })
#if DEBUG
                    .toolbar {
                        if ProductAppStorage.fixtureDirectory != nil {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("내보내기 샘플", systemImage: "shippingbox") {
                                    openDebugExportSample()
                                }
                                .accessibilityIdentifier("debug.export-sample")
                            }
                        }
                    }
#endif
                    .navigationDestination(for: UUID.self) { productID in
                        if let garment = garments.first(where: { $0.id == productID }) {
                            ProductSavedDetailView(garment: garment, controller: controller)
                        }
                    }
                }
                .tint(libraryPath.isEmpty
                    ? (libraryIsEditing ? LibraryStyle.editAccent : LibraryStyle.primary) : Color("HomeAccent"))
            }
            Tab("설정", systemImage: "gearshape.fill", value: HomeTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        // 홈은 중립색, 보관함은 편집 상태에 따른 main의 강조색을 유지합니다.
        .tint(tab == .library && libraryPath.isEmpty
            ? (libraryIsEditing ? LibraryStyle.editAccent : LibraryStyle.primary) : Color.primary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ProductAppStorage.fixtureDirectory != nil {
                Text("연결 흐름 미리보기 · 합성 측정값").font(.caption)
                    .frame(maxWidth: .infinity).padding(6).background(.orange.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .fullScreenCover(item: $creationRequest) { request in
            ProductCreationFlowView(container: context.container, controller: controller, isPresented: creationIsPresented,
                copyHomeProduct: $creationCopyHomeProduct,
                resumeProductID: request.productID,
                onDraftSaved: returnHomeFromCreation,
                onDraftDiscarded: returnHomeFromCreation,
                onFinish: { creationRequest = nil; libraryPath.removeAll(); tab = .library },
                onCancel: { creationRequest = nil })
                .tint(Color("HomeAccent"))
        }
        .fullScreenCover(isPresented: $showLiDAR) {
            LiDARLabView().safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Spacer()
                    Button("닫기") { showLiDAR = false }
                        .font(.body.weight(.semibold)).accessibilityIdentifier("closeLiDARLab")
                }.padding(.horizontal, 20).padding(.vertical, 8).background(.bar)
            }
        }
        .fullScreenCover(item: $exportProduct) { product in
            ExportView(product: product, showFruits: $showFruits)
                .tint(Color("HomeAccent"))
        }
        .alert("내보내기를 열 수 없어요", isPresented: Binding(
            get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("확인", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "") }
        .onOpenURL(perform: handleURL)
        .tint(Color("HomeAccent"))
    }

    private func returnHomeFromCreation() {
        creationRequest = nil
        libraryPath.removeAll()
        tab = .capture
    }

    private func startCreation(resuming productID: UUID? = nil) {
        libraryIsEditing = false
        creationRequest = CreationRequest(productID: productID)
    }

    private var creationIsPresented: Binding<Bool> {
        Binding(get: { creationRequest != nil }, set: { if !$0 { creationRequest = nil } })
    }

#if DEBUG
    private func openDebugExportSample() {
        do {
            let sample = try SampleData.exportSample(in: context)
            libraryPath.removeAll()
            Task { @MainActor in
                await Task.yield()
                libraryPath.append(sample.id)
            }
        } catch {
            linkError = "디버그용 내보내기 샘플을 준비하지 못했어요. \(error.localizedDescription)"
        }
    }
#endif

    private func handleURL(_ url: URL) {
        if ForegroundCopyRelay.canHandle(url) {
            let result = ForegroundCopyRelay.handle(url)
            guard result.copied, let destination = result.destination else { return }
            routeTask?.cancel()
            routeTask = Task { @MainActor in
                if let field = result.field { controller.refresh(); await controller.markCopied(field) }
                guard !Task.isCancelled else { return }
                _ = await UIApplication.shared.open(destination, options: [.universalLinksOnly: true])
            }
            return
        }
        guard url.scheme == "dobby-copy", url.host == "home" else { return }
        controller.refresh()
        guard let session = controller.session else {
            linkError = "진행 중인 복사 도우미가 없어요. 보관함에서 제품을 골라 내보내기를 시작해 주세요."
            return
        }
        let saved = garments.first { $0.id.uuidString == session.productID }.map { ExportProduct(garment: $0) }
        let restored = ExportProduct(id: session.productID, thumbnailData: saved?.thumbnailData,
            marketplacePayload: session.payload, instagramPayload: session.payload,
            measurements: session.measurementItems?.map {
                ExportMeasurement(id: $0.id, title: $0.title, value: $0.value)
            },
            photos: saved?.photos ?? [])
        routeTask?.cancel()
        if creationRequest != nil {
            // A previous product's copy helper can return while a new draft is
            // open. Keep its context and captures alive below the export cover.
            creationCopyHomeProduct = restored
            return
        }
        showLiDAR = false
        exportProduct = nil
        routeTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            showFruits = true
            exportProduct = restored
        }
    }
}

struct ProductSavedDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var garment: Garment
    let controller: CopyActivityController
    @State private var showInformation = false
    @State private var measurementInput = GarmentMeasurementInputState()
    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false

    var body: some View {
        ScrollView {
            ProductDetailCard(garment: garment, measurementAccessibilityPrefix: "library.measurement",
                              photoPresentation: .compact)
                .padding(.horizontal, 21)
                .padding(.vertical, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(ProductInformationStyle.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChakPrimaryButton(title: "플랫폼에 업로드하러 가기") {
                openExport()
            }
                .accessibilityIdentifier("library.export")
                .padding(.horizontal, 33)
                .padding(.top, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(ProductInformationStyle.background.ignoresSafeArea(edges: .bottom))
        }
        .navigationTitle(garment.name.isEmpty ? "이름 없는 \(garment.group.label)" : garment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ProductInformationStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .tint(.primary)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("수정") { showInformation = true }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("library.edit")
            }
        }
        .navigationDestination(isPresented: $showInformation) {
            InfoInputView(garment: garment, measurementInput: $measurementInput,
                          allowsPhotoEditing: true) { _ in
                showInformation = false
            }
        }
        .fullScreenCover(item: $exportProduct) { product in
            ExportView(product: product, showFruits: $showFruits)
        }
#if DEBUG
        .task {
            try? SampleData.upgradeExportSampleIfNeeded(garment, in: context)
        }
#endif
    }

    private func openExport() {
        showFruits = false
        exportProduct = ExportProduct(garment: garment)
    }
}

/// Keeps a small, orientation-correct thumbnail across product field changes.
struct StoredProductPhotoView: View {
    let photo: GarmentPhoto
    let maximumPixelSize: Int
    var contentMode: ContentMode = .fill
    @State private var image: CGImage?
    @State private var imageRequestID: UUID?

    private var thumbnailRequest: ProductThumbnailRequest {
        .init(url: GarmentStore.url(for: photo), maximumPixelSize: maximumPixelSize)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
            }
        }
        .task(id: thumbnailRequest) {
            let request = thumbnailRequest
            let requestID = UUID()
            imageRequestID = requestID
            image = nil
            let decoded = await ProductThumbnailLoader.shared.image(for: request)
            guard !Task.isCancelled, imageRequestID == requestID, thumbnailRequest == request else { return }
            image = decoded?.image
        }
    }
}

#if DEBUG
#Preview("보관함 · 목업 데이터") {
    ContentView(previewLibrary: true)
        .modelContainer(LibraryPreviewData.makeContainer())
        .preferredColorScheme(.light)
}

#Preview("보관함 · 수정 모드") {
    ContentView(previewLibrary: true, previewEditing: true)
        .modelContainer(LibraryPreviewData.makeContainer())
        .preferredColorScheme(.light)
}

#Preview("보관함 · 비어 있음") {
    ContentView(previewLibrary: true)
        .modelContainer(for: [Garment.self, GarmentPhoto.self, LandmarkPoint.self,
            MeasuredValue.self, ExportRecord.self], inMemory: true)
        .preferredColorScheme(.light)
}
#endif
