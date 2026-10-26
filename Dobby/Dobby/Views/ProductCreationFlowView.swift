import SwiftUI
import SwiftData

/// Holds the same product and photo session through the complete creation flow.
struct ProductCreationFlowView: View {
    private enum Step: Hashable { case details, photoSelection, information, completed }
    let controller: CopyActivityController
    let onFinish: () -> Void
    let onCancel: () -> Void
    private let onDraftSaved: () -> Void
    private let resumeProductID: UUID?
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
    @State private var restorationError: String?
    @State private var isRestoring: Bool
    @State private var restoredRecord: SavedMeasurement?
    @State private var measurementRecordID: UUID?
    @State private var preservesDraftPhotos = false

    init(container: ModelContainer, controller: CopyActivityController, isPresented: Binding<Bool>,
         copyHomeProduct: Binding<ExportProduct?>,
         resumeProductID: UUID? = nil, onDraftSaved: (() -> Void)? = nil,
         onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let flowContext = ModelContext(container)
        flowContext.autosaveEnabled = false
        _context = State(initialValue: flowContext)
        _isPresented = isPresented
        _copyHomeProduct = copyHomeProduct
        self.controller = controller
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onDraftSaved = onDraftSaved ?? onCancel
        self.resumeProductID = resumeProductID
        _isRestoring = State(initialValue: resumeProductID != nil)
        isFixture = ProductAppStorage.fixtureDirectory != nil
        archive = MeasurementArchive(folder: ProductAppStorage.fixtureDirectory?.appending(path: "measurements"))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let restorationError {
                    ContentUnavailableView {
                        Label("작업을 불러오지 못했어요", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(restorationError)
                    } actions: {
                        Button("다시 시도") { Task { await restoreDraft() } }
                        Button("나가기", action: onCancel)
                    }
                } else if isRestoring {
                    ProgressView("저장한 작업을 불러오는 중…")
                } else {
                    GarmentCaptureFlowView(archive: archive, preview: isFixture,
                        onConfirmedRecord: receiveMeasurement, onCancel: onCancel, embedsNavigation: false,
                        restoredRecord: restoredRecord, onExitRecord: saveResultAndExit)
                }
            }
                .safeAreaInset(edge: .top, spacing: 0) { fixtureBanner }
                .navigationDestination(for: Step.self) { step in
                    if let garment, let photoModel, let permission {
                        Group {
                            switch step {
                            case .details:
                                CameraFlowView(model: photoModel, permission: permission, camera: camera,
                                    previewSource: isFixture ? photoModel.input.measurement.source : nil,
                                    onSelectPhotos: { path.append(.photoSelection) },
                                    onExit: requestSaveAndExit,
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
                            case .photoSelection:
                                ProductPhotoSelectionView(model: photoModel, onExit: requestSaveAndExit,
                                    onComplete: receivePhotos)
                            case .information:
                                InfoInputView(garment: garment, measurementInput: $measurementInput,
                                    onExit: requestSaveAndExit) {
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
        .disabled(isFinishing)
        .overlay {
            if isFinishing {
                ProgressView("작업을 저장하는 중…").padding().background(.regularMaterial, in: Capsule())
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
                Button("다시 시도") { requestSaveAndExit() }
                Button("확인", role: .cancel) { cleanupError = nil }
            } message: { Text(cleanupError ?? "") }
        .onDisappear {
            guard !isPresented else { return }
            if !preservesDraftPhotos, let photoModel { Task { try? await photoModel.discardUncommittedDetails() } }
        }
        .onChange(of: isPresented) { _, presented in
            // A full-screen export covers the flow but keeps its draft alive.
            // Only the parent dismissing this flow releases temporary captures.
            if !presented, !preservesDraftPhotos, let photoModel {
                Task { try? await photoModel.discardUncommittedDetails() }
            }
        }
        .task { if isRestoring { await restoreDraft() } }
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
        guard record.result.values.contains(where: { value in
            value.status != .unavailable && (value.meters.map { $0.isFinite && $0 > 0 && ($0 * 100).isFinite } ?? false)
        }) else { throw GarmentStore.MeasurementImportError.noAvailableMeasurements }
        let garment = try prepareProduct(for: record)
        try persistDraft(garment, step: .details)
        path.append(.details)
    }

    private func prepareProduct(for record: SavedMeasurement, allowsUnavailableDraft: Bool = false) throws -> Garment {
        if let garment, let photoModel, let permission {
            guard photoModel.input.garmentID == garment.id,
                  photoModel.input.sessionID == record.snapshot.frame.sessionID,
                  garment.measurementPhoto?.measurementFrameID == record.snapshot.frame.frameID,
                  garment.measurementPhoto?.id == photoModel.input.measurement.id else {
                throw CameraFailure.mismatchedCapture
            }
            guard !photoModel.isCapturing, !photoModel.isDeleting else {
                throw CameraFailure.operationInProgress
            }
            if measurementRecordID != record.id {
                try GarmentStore.refreshMeasurement(record, for: garment, in: context,
                    allowsSynthetic: isFixture, allowsUnavailableDraft: allowsUnavailableDraft, save: { _ in })
            }
            measurementRecordID = record.id
            permission.refresh()
            return garment
        }

        let initialDraft = ProductCreationDraft(step: .measurementResult, measurementRecordID: record.id,
            photoState: nil, measurementInputData: nil, savedAt: .now)
        let initialDraftData = try JSONEncoder().encode(initialDraft)
        let imported = try GarmentStore.importMeasurement(record, in: context, allowsSynthetic: isFixture,
            allowsUnavailableDraft: allowsUnavailableDraft,
            save: { insertionContext in
                let identifier = record.id
                let descriptor = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == identifier })
                guard let pending = try insertionContext.fetch(descriptor).first else {
                    throw CameraFailure.missingCapture
                }
                pending.creationDraftData = initialDraftData
                try insertionContext.save()
            })
        try preparePhotoSession(for: imported, record: record)
        garment = imported
        measurementRecordID = record.id
        return imported
    }

    private func preparePhotoSession(for garment: Garment, record: SavedMeasurement,
                                     snapshot: ProductPhotoDraftSnapshot? = nil) throws {
        let input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID)
        let details = try snapshot?.restoredDetailPhotos(for: input) ?? []
        let selected = snapshot?.selectedPhotoIDs ?? [input.measurement.id]
        let model: ProductPhotoModel
#if DEBUG
        if isFixture {
            model = try ProductPhotoModel(input: input,
                captureProvider: ProductPhotoFixtureCaptureProvider(seed: input.measurement.source,
                    directory: ProductAppStorage.fixtureDirectory?.appending(path: "detail-captures")),
                initialDetailPhotos: details, initialSelectedPhotoIDs: selected)
            permission = CameraPermission(authorizer: MockCameraAuthorization())
            camera = nil
        } else {
            let session = CameraPreviewSession()
            model = try ProductPhotoModel(input: input, captureProvider: session,
                initialDetailPhotos: details, initialSelectedPhotoIDs: selected)
            camera = session
            permission = CameraPermission(authorizer: SystemCameraAuthorization())
        }
#else
        let session = CameraPreviewSession()
        model = try ProductPhotoModel(input: input, captureProvider: session,
            initialDetailPhotos: details, initialSelectedPhotoIDs: selected)
        camera = session
        permission = CameraPermission(authorizer: SystemCameraAuthorization())
#endif
        photoModel = model
    }

    private func receivePhotos(_ output: ProductPhotoOutput) async throws {
        guard let garment, let photoModel else { throw CameraFailure.mismatchedCapture }
        try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: photoModel.input)
        try persistDraft(garment, step: .information)
        path.append(.information)
    }

    private func finishFlow() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        try? await photoModel?.discardUncommittedDetails()
        preservesDraftPhotos = false
        onFinish()
    }

    private func saveResultAndExit(_ record: SavedMeasurement) async throws {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        let garment = try prepareProduct(for: record, allowsUnavailableDraft: true)
        try persistDraft(garment, step: .measurementResult)
        onDraftSaved()
    }

    private func requestSaveAndExit() {
        Task { await saveAndExit() }
    }

    private func saveAndExit() async {
        guard !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }
        do {
            guard let garment else { onCancel(); return }
            let step: ProductDraftStep
            switch path.last {
            case .details: step = .details
            case .photoSelection: step = .photoSelection
            case .information: step = .information
            case .completed:
                try context.save()
                try? await photoModel?.discardUncommittedDetails()
                preservesDraftPhotos = false
                onFinish()
                return
            case nil: step = .measurementResult
            }
            try persistDraft(garment, step: step)
        }
        catch { cleanupError = error.localizedDescription; return }
        onDraftSaved()
    }

    private func persistDraft(_ garment: Garment, step: ProductDraftStep) throws {
        // Revisiting photo selection after completion keeps this a saved product.
        if garment.informationCompletedAt != nil {
            try context.save()
            preservesDraftPhotos = false
            return
        }
        guard let measurementRecordID else { throw CameraFailure.mismatchedCapture }
        let inputData = try JSONEncoder().encode(measurementInput)
        try ProductDraftStore.save(garment: garment, step: step, measurementRecordID: measurementRecordID,
            photoModel: photoModel, measurementInputData: inputData, in: context)
        preservesDraftPhotos = true
    }

    private func restoreDraft() async {
        guard let resumeProductID else { isRestoring = false; return }
        restorationError = nil
        isRestoring = true
        do {
            var descriptor = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == resumeProductID })
            descriptor.fetchLimit = 1
            guard let saved = try context.fetch(descriptor).first,
                  saved.isCreationDraft, let draft = saved.creationDraft,
                  saved.sourceMeasurementID == draft.measurementRecordID,
                  draft.step == .measurementResult || draft.photoState != nil else {
                throw CameraFailure.missingCapture
            }
            let record = try await archive.load(draft.measurementRecordID)
            guard saved.measurementPhoto?.measurementFrameID == record.snapshot.frame.frameID else {
                throw CameraFailure.mismatchedCapture
            }
            // A failed restore must never discard photos owned by the saved draft.
            preservesDraftPhotos = true
            try preparePhotoSession(for: saved, record: record, snapshot: draft.photoState)
            if let data = draft.measurementInputData {
                measurementInput = try JSONDecoder().decode(GarmentMeasurementInputState.self, from: data)
            }
            garment = saved
            measurementRecordID = record.id
            restoredRecord = record
            switch draft.step {
            case .measurementResult: path = []
            case .details: path = [.details]
            case .photoSelection: path = [.details, .photoSelection]
            case .information: path = [.details, .photoSelection, .information]
            }
        } catch {
            restorationError = "저장한 작업은 보관함에 남아 있어요. \(error.localizedDescription)"
        }
        isRestoring = false
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
