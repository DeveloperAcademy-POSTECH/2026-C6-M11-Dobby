import SwiftUI
import SwiftData
import UIKit
import ImageIO

struct ContentView: View {
    private enum HomeTab: Hashable { case capture, library, settings }
    private struct CreationRequest: Identifiable {
        let id = UUID()
        let productID: UUID?
        var homeTransition: HomeMeasurementTransitionSeed? = nil
        var homeSnapshot: UIImage? = nil
    }
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var pendingExportDestination: ExportReturnDestination?
    @State private var exportReturnNavigationID = UUID()
    @State private var editingAutofillLoadingPresentation: ProductAutofillLoadingPresentation?
    @State private var homeSnapshotSource = HomeMeasurementSnapshotSource()
    @State private var preparedHomeSnapshot: UIImage?
    @State private var homeMeasurementIdentity = UUID()
    @State private var homeMeasurementHaptics = HomeMeasurementHaptics()

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
                    onStartCapture: { startCreation() },
                    onPrepareMeasurementTransition: prepareHomeMeasurementTransition,
                    onBeginMeasurementTransition: startHomeMeasurementTransition,
                    measurementHaptics: homeMeasurementHaptics)
                    .id(homeMeasurementIdentity)
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
                            ProductSavedDetailView(garment: garment, controller: controller,
                                onExitToLibrary: { libraryPath.removeAll() },
                                onAIGenerationPresentationChange: { editingAutofillLoadingPresentation = $0 })
                        }
                    }
                }
                .tint(libraryPath.isEmpty
                    ? LibraryStyle.primary : Color("HomeAccent"))
            }
            Tab("설정", systemImage: "gearshape.fill", value: HomeTab.settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tint(Color.primary)
        .background { HomeMeasurementSnapshotAnchor(source: homeSnapshotSource).allowsHitTesting(false) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ProductAppStorage.fixtureDirectory != nil {
                Text("연결 흐름 미리보기 · 합성 측정값").font(.caption)
                    .frame(maxWidth: .infinity).padding(6).background(.orange.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(editingAutofillLoadingPresentation == nil)
        .accessibilityHidden(editingAutofillLoadingPresentation != nil)
        .overlay {
            if let presentation = editingAutofillLoadingPresentation {
                ProductAutofillLoadingView(onCancel: presentation.onCancel)
            }
        }
        .fullScreenCover(item: $creationRequest) { request in
            HomeMeasurementPresentation(seed: request.homeTransition, snapshot: request.homeSnapshot) {
                ProductCreationFlowView(container: context.container, controller: controller, isPresented: creationIsPresented,
                    copyHomeProduct: $creationCopyHomeProduct,
                    resumeProductID: request.productID,
                    onDraftSaved: returnHomeFromCreation,
                    onDraftDiscarded: returnHomeFromCreation,
                    onFinish: { creationRequest = nil; libraryPath.removeAll(); tab = .library },
                    onCancel: { creationRequest = nil })
            }
            .tint(Color("HomeAccent"))
        }
        .onChange(of: creationRequest?.id) { previous, current in
            if previous != nil && current == nil {
                homeMeasurementHaptics.stop()
                // TabView can keep Home mounted underneath a full-screen cover.
                // Reset its held gesture/card opacity explicitly on every exit.
                homeMeasurementIdentity = UUID()
                preparedHomeSnapshot = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { homeMeasurementHaptics.stop() }
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
        .fullScreenCover(item: $exportProduct, onDismiss: finishExportDismissal) { product in
            ExportView(product: product, showFruits: $showFruits) { destination in
                routeTask?.cancel()
                routeTask = nil
                pendingExportDestination = destination
                showFruits = false
                exportProduct = nil
            }
                .tint(Color("HomeAccent"))
        }
        .alert("내보내기를 열 수 없어요", isPresented: Binding(
            get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("확인", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "") }
        .onOpenURL(perform: handleURL)
        .tint(Color("HomeAccent"))
        .environment(\.returnFromExport,
            ExportReturnNavigationAction(id: exportReturnNavigationID, action: { @MainActor destination in
                returnFromExport(to: destination)
            }))
    }

    private func finishExportDismissal() {
        guard let destination = pendingExportDestination else { return }
        pendingExportDestination = nil
        returnFromExport(to: destination)
    }

    private func returnFromExport(to destination: ExportReturnDestination) {
        routeTask?.cancel()
        routeTask = nil
        creationCopyHomeProduct = nil
        linkError = nil
        exportProduct = nil
        showFruits = false
        showLiDAR = false
        creationRequest = nil
        libraryPath.removeAll()
        libraryIsEditing = false
        tab = destination == .library ? .library : .capture
    }

    private func returnHomeFromCreation() {
        creationRequest = nil
        libraryPath.removeAll()
        tab = .capture
    }

    private func startCreation(resuming productID: UUID? = nil) {
        guard creationRequest == nil else { return }
        homeMeasurementHaptics.stop()
        preparedHomeSnapshot = nil
        libraryIsEditing = false
        creationRequest = CreationRequest(productID: productID)
    }

    private func prepareHomeMeasurementTransition() {
        guard creationRequest == nil, tab == .capture else { return }
        // Capture the live home, including its current draft card and native
        // tab bar, before the first drag changes its appearance.
        preparedHomeSnapshot = homeSnapshotSource.snapshot()
    }

    private func startHomeMeasurementTransition(_ seed: HomeMeasurementTransitionSeed) {
        guard creationRequest == nil, tab == .capture else { return }
        libraryIsEditing = false
        let snapshot = preparedHomeSnapshot ?? homeSnapshotSource.snapshot()
        let canvasSize = homeSnapshotSource.canvasSize ?? seed.canvasSize
        let request = CreationRequest(productID: nil,
            homeTransition: .init(pull: seed.pull, canvasSize: canvasSize), homeSnapshot: snapshot)
        preparedHomeSnapshot = nil
        // Only this entry replaces UIKit's cover slide with the designed wipe.
        // Resume and library entry keep their existing presentation behaviour.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        homeMeasurementHaptics.finishPull()
        withTransaction(transaction) { creationRequest = request }
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
    @Environment(\.returnFromExport) private var returnFromExport
    @Bindable var garment: Garment
    let controller: CopyActivityController
    let onExitToLibrary: () -> Void
    var onAIGenerationPresentationChange: ((ProductAutofillLoadingPresentation?) -> Void)? = nil
    @State private var showInformation = false
    @State private var editSession: ProductInformationEditSession?
    @State private var editError: String?
    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false
    @State private var pendingExportDestination: ExportReturnDestination?

    var body: some View {
        ScrollView {
            ProductDetailCard(garment: garment, measurementAccessibilityPrefix: "library.measurement",
                              photoPresentation: .compact, style: .library)
                .padding(.horizontal, 21)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(LibraryStyle.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: openExport) {
                Text("플랫폼에 업로드하러 가기")
                    .font(LibraryDetailTypography.upload)
                    .tracking(-0.31)
            }
                .buttonStyle(ChakPrimaryButtonStyle(variant: .solid))
                .accessibilityIdentifier("library.export")
                .padding(.horizontal, 33.5)
                .padding(.top, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(LibraryStyle.background.ignoresSafeArea(edges: .bottom))
        }
        .navigationTitle(garment.name.isEmpty ? "이름 없는 \(garment.group.label)" : garment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LibraryStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .tint(.primary)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("수정", action: openInformation)
                    .font(LibraryDetailTypography.edit)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("library.edit")
            }
        }
        .navigationDestination(isPresented: $showInformation) {
            if let editSession {
                ProductInformationEditingView(session: editSession,
                    onExit: { showInformation = false },
                    onDiscard: {
                        showInformation = false
                        onExitToLibrary()
                    }, onComplete: { _ in
                        editSession.reflectSavedChanges(in: garment)
                        showInformation = false
                    }, onAIGenerationPresentationChange: onAIGenerationPresentationChange)
            }
        }
        .alert("제품 정보를 열 수 없어요", isPresented: Binding(
            get: { editError != nil }, set: { if !$0 { editError = nil } }
        )) {
            Button("확인", role: .cancel) { editError = nil }
        } message: {
            Text(editError ?? "")
        }
        .fullScreenCover(item: $exportProduct, onDismiss: finishExportDismissal) { product in
            ExportView(product: product, showFruits: $showFruits) { destination in
                pendingExportDestination = destination
                showFruits = false
                exportProduct = nil
            }
        }
#if DEBUG
        .task {
            try? SampleData.upgradeExportSampleIfNeeded(garment, in: context)
        }
#endif
    }

    private func openExport() {
        pendingExportDestination = nil
        showFruits = false
        exportProduct = ExportProduct(garment: garment)
    }

    private func openInformation() {
        do {
            editSession = try ProductInformationEditSession(garmentID: garment.id,
                                                          container: context.container)
            showInformation = true
        } catch {
            editError = "저장된 상품을 불러오지 못했어요. 다시 시도해 주세요."
        }
    }

    private func finishExportDismissal() {
        guard let destination = pendingExportDestination else { return }
        pendingExportDestination = nil
        returnFromExport?(to: destination)
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
