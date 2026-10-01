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
    @State private var showCreation = false
    @State private var creationCopyHomeProduct: ExportProduct?
    @State private var showLiDAR = false
    @State private var exportProduct: ExportProduct?
    @State private var pendingExportEdit: Garment?
    @State private var libraryEditProduct: Garment?
    @State private var showFruits = false
    @State private var controller = CopyActivityController()
    @State private var linkError: String?
    @State private var routeTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $tab) {
            Tab("홈", systemImage: "house", value: .capture) {
                NavigationStack {
                    VStack(spacing: 24) {
                        Spacer()
                        Image("CameraShutter").resizable().scaledToFit().frame(width: 200, height: 180)
                            .accessibilityHidden(true)
                        Text("사진 한 장으로 시작하세요").font(.title2.bold())
                        Text("실측부터 제품 정보와 내보내기까지 이어서 준비해요.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button { showCreation = true } label: {
                            Label("옷 촬영 · 실측", systemImage: "ruler")
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                        .accessibilityIdentifier("product-flow.start")
                        Spacer()
#if DEBUG
                        Button("측정 실험실") { showLiDAR = true }
                            .font(.footnote).accessibilityIdentifier("openLiDARLab")
#endif
                    }.padding(24).navigationTitle("Dobby")
                }
            }
            Tab("보관함", systemImage: "hanger", value: .library) {
                NavigationStack(path: $libraryPath) {
                    Group {
                        if garments.isEmpty {
                            ContentUnavailableView("보관된 제품이 없어요", systemImage: "hanger",
                                description: Text("옷을 촬영하고 실측하면 여기에 보관돼요."))
                        } else {
                            List(garments) { garment in
                                NavigationLink(value: garment.id) {
                                    HStack(spacing: 14) {
                                        if let photo = garment.thumbnail {
                                            StoredProductPhotoView(photo: photo, maximumPixelSize: 240)
                                                .frame(width: 64, height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                                        } else {
                                            Image(systemName: "tshirt").frame(width: 64, height: 80)
                                        }
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(garment.name.isEmpty ? "이름 없는 \(garment.group.label)" : garment.name)
                                                .font(.headline)
                                            Text("\(garment.orderedMeasurements.count)개 실측 · \(garment.productPhotos.count)장 사진")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if garment.sourceMeasurementID != nil && garment.informationCompletedAt == nil {
                                                Text("작성 중 · 이어서 입력할 수 있어요").font(.caption).foregroundStyle(.orange)
                                            }
                                        }
                                    }
                                }.accessibilityIdentifier("library.product.\(garment.id.uuidString)")
                            }.accessibilityIdentifier("library.products")
                        }
                    }
                    .navigationTitle("보관함")
                    .navigationDestination(for: UUID.self) { productID in
                        if let garment = garments.first(where: { $0.id == productID }) {
                            ProductSavedDetailView(garment: garment, controller: controller,
                                onLibrary: { libraryPath.removeAll() })
                        }
                    }
                }
            }
        }
        .tint(.orange)
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
        .fullScreenCover(item: $exportProduct, onDismiss: {
            if let garment = pendingExportEdit {
                pendingExportEdit = nil
                tab = .library
                libraryEditProduct = garment
            }
        }) { product in
            ExportView(product: product, controller: controller, showFruits: $showFruits,
                       onEditProduct: exportEditAction(for: product))
        }
        .sheet(item: $libraryEditProduct) { garment in
            NavigationStack {
                ProductSavedDetailView(garment: garment, controller: controller,
                    onLibrary: { libraryEditProduct = nil; libraryPath.removeAll() }, initiallyEditing: true)
            }
        }
        .alert("내보내기를 열 수 없어요", isPresented: Binding(
            get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
                Button("확인", role: .cancel) { linkError = nil }
            } message: { Text(linkError ?? "") }
        .onOpenURL(perform: handleURL)
    }

    private func exportEditAction(for product: ExportProduct) -> (() -> Void)? {
        guard let garment = garments.first(where: { $0.id.uuidString == product.id }) else { return nil }
        return { pendingExportEdit = garment; exportProduct = nil }
    }

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
    @Bindable var garment: Garment
    let controller: CopyActivityController
    let onLibrary: () -> Void
    var initiallyEditing = false
    @State private var showCompletion = false
    @State private var showInformation = false
    @State private var didOpenInitialEdit = false
    @State private var pendingExportEdit = false
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
                ForEach(garment.orderedMeasurements) { value in
                    LabeledContent(value.label, value: value.valueCm.formatted(.number.precision(.fractionLength(0...2))) + " cm")
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
            InfoInputView(garment: garment) { _ in showCompletion = true }
        }
        .navigationDestination(isPresented: $showCompletion) {
            ProductInputCompletionView(garment: garment, onExport: openExport, onLibrary: onLibrary)
        }
        .fullScreenCover(item: $exportProduct, onDismiss: {
            if pendingExportEdit {
                pendingExportEdit = false
                showCompletion = false
                showInformation = true
            }
        }) { product in
            ExportView(product: product, controller: controller, showFruits: $showFruits,
                       onEditProduct: { pendingExportEdit = true; exportProduct = nil })
        }
        .task {
            if initiallyEditing, !didOpenInitialEdit {
                didOpenInitialEdit = true
                showInformation = true
            }
        }
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
#Preview {
    ContentView().modelContainer(for: [Garment.self, GarmentPhoto.self, LandmarkPoint.self,
        MeasuredValue.self, ExportRecord.self], inMemory: true)
}
#endif
