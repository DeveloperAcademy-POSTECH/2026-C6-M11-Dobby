import SwiftUI
import SwiftData
import UIKit
import ImageIO

struct ContentView: View {
    private enum HomeTab: Hashable { case capture, library }
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.updatedAt, order: .reverse) private var garments: [Garment]
    @State private var tab: HomeTab = .capture
    @State private var libraryPath: [UUID] = []
    @State private var libraryIsEditing = false
    @State private var showCreation = false
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
                HomeView { showCreation = true }
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
                        onStartMeasurement: { showCreation = true })
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
                                onLibrary: { libraryPath.removeAll() })
                        }
                    }
                }
            }
        }
        .tint(tab == .library && libraryPath.isEmpty
            ? (libraryIsEditing ? LibraryStyle.editAccent : LibraryStyle.primary) : Color("HomeAccent"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if ProductAppStorage.fixtureDirectory != nil {
                Text("연결 흐름 미리보기 · 합성 측정값").font(.caption)
                    .frame(maxWidth: .infinity).padding(6).background(.orange.opacity(0.15))
            }
        }
        .fullScreenCover(isPresented: $showCreation) {
            ProductCreationFlowView(container: context.container, controller: controller, isPresented: $showCreation,
                copyHomeProduct: $creationCopyHomeProduct,
                onFinish: { showCreation = false; libraryPath.removeAll(); tab = .library },
                onCancel: { showCreation = false })
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
            ExportView(product: product, controller: controller, showFruits: $showFruits)
                .tint(Color("HomeAccent"))
        }
        .alert("내보내기를 열 수 없어요", isPresented: Binding(
            get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("확인", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "") }
        .onOpenURL(perform: handleURL)
#if DEBUG
        .task {
            try? SampleData.refreshExportSampleIfPresent(in: context)
        }
#endif
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
        let restored = ExportProduct(id: session.productID, imageData: saved?.imageData,
            fruits: session.payload, instagram: session.payload,
            detailMeasurements: session.measurementItems?.map { ExportMeasurement(id: $0.id, title: $0.title, value: $0.value) },
            photoData: saved?.photoData ?? [])
        routeTask?.cancel()
        if showCreation {
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
    let onLibrary: () -> Void
    @State private var showCompletion = false
    @State private var showInformation = false
    @State private var measurementInput = GarmentMeasurementInputState()
    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    if let photo = garment.thumbnail {
                        StoredProductPhotoView(photo: photo, maximumPixelSize: 700, contentMode: .fit)
                            .frame(height: 150)
                    }
                    Text(garment.name.isEmpty ? "이름 없는 \(garment.group.label)" : garment.name)
                        .font(.subheadline.weight(.semibold))
                }.frame(maxWidth: .infinity)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(garment.productPhotos) { photo in
                            StoredProductPhotoView(photo: photo, maximumPixelSize: 320)
                                .frame(width: 92, height: 112).clipped()
                        }
                    }
                }
                if !garment.detail.isEmpty { Text(garment.detail) }
                if !garment.brand.isEmpty { LabeledContent("브랜드", value: garment.brand) }
                Text("실측 사이즈").font(.headline)
                ForEach(garment.visibleMeasurements) { value in
                    LabeledContent(value.displayLabel, value: MeasurementDisplayText.centimeters(value.valueCm) + " cm")
                        .accessibilityIdentifier("library.measurement.\(value.key)")
                }
                Button("내보내기") { openExport() }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("library.export")
            }.padding(20)
        }
        .navigationTitle("제품 상세").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("수정") { showInformation = true }
                    .accessibilityIdentifier("library.edit")
            }
        }
        .navigationDestination(isPresented: $showInformation) {
            InfoInputView(garment: garment, measurementInput: $measurementInput) { _ in showCompletion = true }
        }
        .navigationDestination(isPresented: $showCompletion) {
            ProductInputCompletionView(garment: garment, onExport: openExport, onLibrary: onLibrary)
        }
        .fullScreenCover(item: $exportProduct) { product in
            ExportView(product: product, controller: controller, showFruits: $showFruits)
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

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
            }
        }
        .task(id: photo.fileName) {
            guard let source = CGImageSourceCreateWithURL(GarmentStore.url(for: photo) as CFURL, nil) else { return }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary)
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
