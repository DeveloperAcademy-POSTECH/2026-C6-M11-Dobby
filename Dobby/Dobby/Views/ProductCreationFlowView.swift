import SwiftUI
import SwiftData

/// Holds the same product and photo session through the complete creation flow.
struct ProductCreationFlowView: View {
    private enum Step: Hashable { case details, information, completed }
    let controller: CopyActivityController
    let onFinish: () -> Void
    let onCancel: () -> Void
    @Binding private var isPresented: Bool
    @Binding private var copyHomeProduct: ExportProduct?
    @State private var context: ModelContext
    private let archive: MeasurementArchive
    private let isFixture: Bool
    @State private var path: [Step] = []
    @State private var garment: Garment?
    @State private var measurementInput = GarmentMeasurementInputState()
    @State private var photoModel: ProductPhotoModel?
    @State private var camera: CameraPreviewSession?
    @State private var permission: CameraPermission?
    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false
    @State private var isFinishing = false
    @State private var cleanupError: String?

    init(container: ModelContainer, controller: CopyActivityController, isPresented: Binding<Bool>,
         copyHomeProduct: Binding<ExportProduct?>,
         onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let flowContext = ModelContext(container)
        flowContext.autosaveEnabled = false
        _context = State(initialValue: flowContext)
        _isPresented = isPresented
        _copyHomeProduct = copyHomeProduct
        self.controller = controller
        self.onFinish = onFinish
        self.onCancel = onCancel
        isFixture = ProductAppStorage.fixtureDirectory != nil
        archive = MeasurementArchive(folder: ProductAppStorage.fixtureDirectory?.appending(path: "measurements"))
    }

    var body: some View {
        NavigationStack(path: $path) {
            GarmentCaptureFlowView(archive: archive, preview: isFixture,
                onConfirmedRecord: receiveMeasurement, onCancel: onCancel, embedsNavigation: false)
                .safeAreaInset(edge: .top, spacing: 0) { fixtureBanner }
                .navigationDestination(for: Step.self) { step in
                    if let garment, let photoModel, let permission {
                        Group {
                            switch step {
                            case .details:
                                CameraFlowView(model: photoModel, permission: permission, camera: camera,
                                    previewSource: isFixture ? photoModel.input.measurement.source : nil,
                                    onComplete: receivePhotos)
                                    .navigationBarBackButtonHidden()
                                    .toolbar {
                                        ToolbarItem(placement: .topBarLeading) {
                                            Button("실측 결과로 돌아가기", systemImage: "chevron.left") {
                                                guard path.last == .details else { return }
                                                path.removeLast()
                                            }
                                            .labelStyle(.iconOnly)
                                            .accessibilityIdentifier("product-flow.backToMeasurement")
                                        }
                                    }
                            case .information:
                                InfoInputView(garment: garment, measurementInput: $measurementInput) {
                                    _ in path.append(.completed)
                                }
                            case .completed:
                                ProductInputCompletionView(garment: garment,
                                    onExport: { showFruits = false; exportProduct = ExportProduct(garment: garment) },
                                    onLibrary: { Task { await finishFlow() } })
                            }
                        }.safeAreaInset(edge: .top, spacing: 0) { fixtureBanner }
                    }
                }
        }
        .environment(\.modelContext, context)
        .preferredColorScheme(path.last == .information || path.last == .completed ? .light : .dark)
        .tint(path.last == .information || path.last == .completed ? .orange : .white)
        .fullScreenCover(item: $exportProduct) { product in
            ExportView(product: product, controller: controller, showFruits: $showFruits)
                .environment(\.modelContext, context)
                .preferredColorScheme(.light)
        }
        .onChange(of: copyHomeProduct?.id) { _, _ in
            guard let product = copyHomeProduct else { return }
            showFruits = true
            exportProduct = product
            copyHomeProduct = nil
        }
        .alert("작성 중인 제품을 저장하지 못했어요", isPresented: Binding(
            get: { cleanupError != nil }, set: { if !$0 { cleanupError = nil } })) {
                Button("다시 시도") { Task { await cancelFlow() } }
                Button("확인", role: .cancel) { cleanupError = nil }
            } message: { Text(cleanupError ?? "") }
        .onDisappear {
            guard !isPresented else { return }
            if let photoModel { Task { try? await photoModel.discardUncommittedDetails() } }
        }
        .onChange(of: isPresented) { _, presented in
            // A full-screen export covers the flow but keeps its draft alive.
            // Only the parent dismissing this flow releases temporary captures.
            if !presented, let photoModel { Task { try? await photoModel.discardUncommittedDetails() } }
        }
    }

    @ViewBuilder
    private var fixtureBanner: some View {
        if isFixture {
            Text("연결 흐름 미리보기 · 합성 측정값")
                .font(.caption).frame(maxWidth: .infinity).padding(6).background(.orange.opacity(0.15))
                .accessibilityIdentifier("product-flow.fixture")
        }
    }

    private func receiveMeasurement(_ record: SavedMeasurement) async throws {
        // 같은 결과의 재확인은 사진·선택 순서·카메라 세션을 그대로 이어 간다.
        if let garment, garment.sourceMeasurementID == record.id,
           let photoModel, let permission {
            guard photoModel.input.garmentID == garment.id,
                  photoModel.input.sessionID == record.snapshot.frame.sessionID,
                  garment.measurementPhoto?.measurementFrameID == record.snapshot.frame.frameID,
                  garment.measurementPhoto?.id == photoModel.input.measurement.id else {
                throw CameraFailure.mismatchedCapture
            }
            guard !photoModel.isCapturing, !photoModel.isDeleting else {
                throw CameraFailure.operationInProgress
            }
            // 권한은 설정 앱에서 바뀌었을 수 있으므로 같은 객체에서 다시 확인한다.
            permission.refresh()
            path.append(.details)
            return
        }

        let imported = try GarmentStore.importMeasurement(record, in: context, allowsSynthetic: isFixture)
        let input = try ProductPhotoHandoff.makeInput(for: imported, sessionID: record.snapshot.frame.sessionID)
        let model: ProductPhotoModel
#if DEBUG
        if isFixture {
            model = try ProductPhotoModel(input: input,
                captureProvider: ProductPhotoFixtureCaptureProvider(seed: input.measurement.source,
                    directory: ProductAppStorage.fixtureDirectory?.appending(path: "detail-captures")),
                initialSelectedPhotoIDs: [input.measurement.id])
            permission = CameraPermission(authorizer: MockCameraAuthorization())
            camera = nil
        } else {
            let session = CameraPreviewSession()
            model = try ProductPhotoModel(input: input, captureProvider: session,
                initialSelectedPhotoIDs: [input.measurement.id])
            camera = session
            permission = CameraPermission(authorizer: SystemCameraAuthorization())
        }
#else
        let session = CameraPreviewSession()
        model = try ProductPhotoModel(input: input, captureProvider: session,
            initialSelectedPhotoIDs: [input.measurement.id])
        camera = session
        permission = CameraPermission(authorizer: SystemCameraAuthorization())
#endif
        garment = imported
        photoModel = model
        path.append(.details)
    }

    private func receivePhotos(_ output: ProductPhotoOutput) async throws {
        guard let garment, let photoModel else { throw CameraFailure.mismatchedCapture }
        try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: photoModel.input)
        path.append(.information)
    }

    private func finishFlow() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        try? await photoModel?.discardUncommittedDetails()
        onFinish()
    }

    private func cancelFlow() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        do { try context.save() }
        catch { cleanupError = error.localizedDescription; return }
        try? await photoModel?.discardUncommittedDetails()
        onCancel()
    }
}

struct ProductInputCompletionView: View {
    let garment: Garment
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("CameraShutter").resizable().scaledToFit().frame(width: 180, height: 150)
                .accessibilityHidden(true)
            Text("제품 정보 입력 완료!").font(.title2.bold())
            Text(garment.name.isEmpty ? "제품의 사진과 실측값을 저장했어요." : "\(garment.name)의 사진과 실측값을 저장했어요.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Button("내보내기", action: onExport)
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .frame(maxWidth: .infinity).accessibilityIdentifier("product-complete.export")
            Button("보관함으로 이동하기", action: onLibrary)
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                .accessibilityIdentifier("product-complete.library")
        }.padding(24).navigationTitle("제품 정보 입력 완료").navigationBarTitleDisplayMode(.inline)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product-complete.screen")
    }
}
