import SwiftUI
import SwiftData
import UIKit

/// Holds the same product and photo session through the complete creation flow.
struct ProductCreationFlowView: View {
    @Environment(\.returnHomeFromExport) private var returnHomeFromExport
    private enum Step: Hashable { case details, information, completed }
    private enum ExitAction { case save, discard }
    let controller: CopyActivityController
    let onFinish: () -> Void
    let onCancel: () -> Void
    private let onDraftSaved: () -> Void
    private let onDraftDiscarded: () -> Void
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
    @State private var cleanupAction: ExitAction = .save
    @State private var restorationError: String?
    @State private var isRestoring: Bool
    @State private var restoredRecord: SavedMeasurement?
    @State private var measurementRecordID: UUID?
    @State private var preservesDraftPhotos = false
    @State private var pendingExitAction: (() -> Void)?
    @State private var usesProductAutofill = true
    @State private var autofill = ProductAutofillSession()
    @State private var autofillReviewNotes: [String] = []
    @State private var autofillLoadingPresentation: ProductAutofillLoadingPresentation?
    @State private var returnsHomeAfterExport = false

    init(container: ModelContainer, controller: CopyActivityController, isPresented: Binding<Bool>,
         copyHomeProduct: Binding<ExportProduct?>,
         resumeProductID: UUID? = nil, onDraftSaved: (() -> Void)? = nil,
         onDraftDiscarded: (() -> Void)? = nil,
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
        self.onDraftDiscarded = onDraftDiscarded ?? onDraftSaved ?? onCancel
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
                        restoredRecord: restoredRecord)
                }
            }
                .safeAreaInset(edge: .top, spacing: 0) { fixtureBanner }
                .navigationDestination(for: Step.self) { step in
                    destination(for: step)
                }
        }
        // Each generation screen locks its own controls. Disabling this ancestor
        // would also disable native error-alert actions created as loading ends.
        .disabled(isFinishing || pendingExitAction != nil)
        .accessibilityHidden(autofillLoadingPresentation != nil)
        .overlay {
            if let presentation = autofillLoadingPresentation {
                ProductAutofillLoadingView(onCancel: presentation.onCancel)
            }
        }
        .overlay {
            if isFinishing {
                ProgressView(cleanupAction == .discard ? "작업을 삭제하는 중…" : "작업을 저장하는 중…")
                    .padding().background(.regularMaterial, in: Capsule())
            }
        }
        .overlay {
            if pendingExitAction != nil {
                ProductDraftExitConfirmation(onCancel: { pendingExitAction = nil },
                    onSave: confirmDraftExit, onDiscard: requestDiscardAndExit)
            }
        }
        .environment(\.modelContext, context)
        .tint(path.last == .information ? .black
            : path.last == .completed ? .orange : .white)
        .fullScreenCover(item: $exportProduct, onDismiss: finishExportDismissal) { product in
            ExportView(product: product, showFruits: $showFruits,
                onClose: closeExport)
                .environment(\.modelContext, context)
                .preferredColorScheme(.light)
                .disabled(isFinishing)
        }
        .onChange(of: exportProduct?.id) { _, productID in
            if productID != nil { returnsHomeAfterExport = false }
        }
        .onChange(of: copyHomeProduct?.id) { _, _ in
            guard let product = copyHomeProduct else { return }
            showFruits = true
            exportProduct = product
            copyHomeProduct = nil
        }
        .alert(cleanupAction == .discard ? "작성 중인 제품을 삭제하지 못했어요" : "작성 중인 제품을 저장하지 못했어요", isPresented: Binding(
            get: { cleanupError != nil }, set: { if !$0 { cleanupError = nil } })) {
                Button("다시 시도") {
                    if cleanupAction == .discard { requestDiscardAndExit() }
                    else { requestSaveAndExit() }
                }
                Button("확인", role: .cancel) { cleanupError = nil }
            } message: { Text(cleanupError ?? "") }
        .onDisappear {
            guard !isPresented else { return }
            if !preservesDraftPhotos, let photoModel { Task { try? await photoModel.discardUncommittedDetails() } }
        }
        .onChange(of: isPresented) { _, presented in
            // A full-screen export covers the flow but keeps its draft alive.
            // Only the parent dismissing this flow releases temporary captures.
            if !presented {
                autofill.cancel()
                autofillLoadingPresentation = nil
                pendingExitAction = nil
                if !preservesDraftPhotos, let photoModel {
                    Task { try? await photoModel.discardUncommittedDetails() }
                }
            }
        }
        .task { if isRestoring { await restoreDraft() } }
        .onChange(of: garment?.productPhotos.map(\.id)) { _, _ in
            guard path.last == .information else { return }
            synchronizeInformationPhotoSelection()
        }
    }

    @ViewBuilder
    private func destination(for step: Step) -> some View {
        if let garment, let photoModel, let permission {
            Group {
                switch step {
                case .details:
                    CameraFlowView(model: photoModel, permission: permission, camera: camera,
                        previewSource: isFixture ? photoModel.input.measurement.source : nil,
                        onExit: returnToMeasurementResult, onComplete: receiveAllCapturedPhotos)
                case .information:
                    // Restored creation drafts continue input; they are not saved-product edits.
                    InfoInputView(garment: garment, measurementInput: $measurementInput,
                        onExit: handleInformationBack, onGenerateAI: generateInformationFromButton,
                        onCancelGeneration: { autofill.cancel() },
                        onAIGenerationPresentationChange: { autofillLoadingPresentation = $0 }) {
                        _ in
                        synchronizeInformationPhotoSelection()
                        path.append(.completed)
                    }
                case .completed:
                    ProductInputCompletionView(garment: garment,
                        onExport: { showFruits = false; exportProduct = ExportProduct(garment: garment) },
                        onLibrary: { Task { await finishFlow() } })
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { fixtureBanner }
            .preferredColorScheme(step == .details ? .dark : .light)
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

    private func returnToMeasurementResult() {
        guard path.last == .details, !isFinishing, pendingExitAction == nil,
              let photoModel, !photoModel.isCapturing, !photoModel.isDeleting else { return }
        // Pop only the detail screen; retain the measurement result and photo session.
        path.removeLast()
    }

    private func handleInformationBack() {
        guard path.last == .information, !isFinishing, let garment else { return }
        synchronizeInformationPhotoSelection()
        // Use the Done button's enabled condition, not full completion validation.
        if GarmentInformationValidation.hasAnyInformation(garment) {
            requestDraftExit()
        } else {
            // Both new and restored drafts return to the same capture session.
            // Do not rebuild the model or pass through the retired selection screen.
            path = [.details]
        }
    }

    @discardableResult
    private func synchronizeInformationPhotoSelection() -> Bool {
        guard let garment, let photoModel else { return false }
        do {
            try photoModel.synchronizeStoredProductPhotos(garment.productPhotos)
            return photoModel.synchronizeSelectedProductPhotos(garment.productPhotos.prefix(ProductPhotoModel.maximumSelectionCount).map(\.id))
        } catch {
            return false
        }
    }

    private func receiveMeasurement(_ record: SavedMeasurement) async throws {
        guard record.result.values.contains(where: { value in
            value.status != .unavailable && (value.meters.map { $0.isFinite && $0 > 0 && ($0 * 100).isFinite } ?? false)
        }) else { throw GarmentStore.MeasurementImportError.noAvailableMeasurements }
        try await prepareAndSaveProduct(for: record, step: .details)
        path.append(.details)
    }

    private func prepareAndSaveProduct(for record: SavedMeasurement, step: ProductDraftStep,
                                       allowsUnavailableDraft: Bool = false) async throws {
        if let garment, let photoModel,
           garment.measurementPhoto?.measurementFrameID != record.snapshot.frame.frameID
            || garment.measurementPhoto?.measurementSessionID != record.snapshot.frame.sessionID {
            let replacementInput = GarmentMeasurementInputState()
            let replacement = try await ProductMeasurementRetake.replace(record, garment: garment,
                photoModel: photoModel, previousInputData: JSONEncoder().encode(measurementInput),
                replacementInputData: JSONEncoder().encode(replacementInput), step: step, in: context,
                allowsSynthetic: isFixture, allowsUnavailableDraft: allowsUnavailableDraft)
            context = replacement.context
            self.garment = replacement.garment
            self.photoModel = replacement.photoModel
            measurementRecordID = record.id
            measurementInput = replacementInput
            preservesDraftPhotos = true
            permission?.refresh()
        } else {
            let garment = try await prepareProduct(for: record, allowsUnavailableDraft: allowsUnavailableDraft)
            try persistDraft(garment, step: step)
        }
    }

    private func prepareProduct(for record: SavedMeasurement, allowsUnavailableDraft: Bool = false) async throws -> Garment {
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
            let visualization = try await MeasurementProductPhoto.prepare(record: record, garment: garment, in: context)
            try photoModel.updateMeasurementRecord(record, visualization: visualization)
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
        try await preparePhotoSession(for: imported, record: record)
        garment = imported
        measurementRecordID = record.id
        return imported
    }

    private func preparePhotoSession(for garment: Garment, record: SavedMeasurement,
                                     snapshot: ProductPhotoDraftSnapshot? = nil) async throws {
        var input = try ProductPhotoHandoff.makeInput(for: garment, sessionID: record.snapshot.frame.sessionID)
        input.measurementVisualization = try await MeasurementProductPhoto.prepare(record: record, garment: garment, in: context)
        let details = try snapshot?.restoredDetailPhotos(for: input) ?? []
        let selected = snapshot?.selectedPhotoIDs ?? [input.measurement.id]
        let model: ProductPhotoModel
#if DEBUG
        if isFixture {
            model = try ProductPhotoModel(input: input,
                captureProvider: ProductPhotoFixtureCaptureProvider(seed: input.measurement.source,
                    directory: ProductAppStorage.fixtureDirectory?.appending(path: "detail-captures")),
                initialDetailPhotos: details, initialSelectedPhotoIDs: selected, measurementRecord: record,
                initialDeletedPhotoIDs: snapshot?.deletedPhotoIDs ?? [])
            permission = CameraPermission(authorizer: MockCameraAuthorization())
            camera = nil
        } else {
            let session = CameraPreviewSession()
            model = try ProductPhotoModel(input: input, captureProvider: session,
                initialDetailPhotos: details, initialSelectedPhotoIDs: selected, measurementRecord: record,
                initialDeletedPhotoIDs: snapshot?.deletedPhotoIDs ?? [])
            camera = session
            permission = CameraPermission(authorizer: SystemCameraAuthorization())
        }
#else
        let session = CameraPreviewSession()
        model = try ProductPhotoModel(input: input, captureProvider: session,
            initialDetailPhotos: details, initialSelectedPhotoIDs: selected, measurementRecord: record,
                initialDeletedPhotoIDs: snapshot?.deletedPhotoIDs ?? [])
        camera = session
        permission = CameraPermission(authorizer: SystemCameraAuthorization())
#endif
        if snapshot?.hasAcknowledgedCaptureGuide == true {
            model.acknowledgeCaptureGuide()
        }
        photoModel = model
    }

    private func receiveAllCapturedPhotos(_ output: ProductPhotoOutput) async throws {
        guard isPresented, path.last == .details, let garment, let photoModel else {
            throw CameraFailure.mismatchedCapture
        }
        // 상품 반영과 삭제 내역이 담긴 초안을 한 번에 저장해 이전 사진이 복원되지 않게 한다.
        try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: photoModel.input,
            includesAllCapturedPhotos: true, persist: { _ in
                try persistDraft(garment, step: .information)
            })
        try Task.checkCancellation()
        guard isPresented, path.last == .details else { throw CancellationError() }
        path.append(.information)
    }

    private func generateInformationFromButton() async throws {
        guard synchronizeInformationPhotoSelection() else { throw ProductAutofillError.invalidPhotos }
        guard let garment, let output = photoModel?.output,
              path.last == .information else {
            throw ProductAutofillError.invalidPhotos
        }
        // Retain the seller's latest input even if they cancel or close the app.
        try persistDraft(garment, step: .information)
        try await generateAndApplyInformation(output, expectedStep: .information)
    }

    private func generateAndApplyInformation(_ output: ProductPhotoOutput, expectedStep: Step) async throws {
        guard let garment, let photoModel, isPresented, path.last == expectedStep else {
            throw CancellationError()
        }

        let before = ProductAutofillInputSnapshot(garment: garment)
        do {
            let draft = try await autofill.generate(photos: output.selectedPhotos)
            try Task.checkCancellation()
            guard isPresented, path.last == expectedStep,
                  self.garment?.id == output.garmentID,
                  photoModel.output?.selectedPhotos == output.selectedPhotos else {
                throw CancellationError()
            }
            try before.apply(draft, to: garment)
            let previousReviewNotes = autofillReviewNotes
            autofillReviewNotes = draft.reviewNotes
            do {
                try persistDraft(garment, step: .information)
            } catch {
                before.restore(to: garment)
                autofillReviewNotes = previousReviewNotes
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ProductAutofillCompletionFailure.generation(error.localizedDescription)
        }
    }

    private func finishFlow(returningHome: Bool = false) async {
        guard !isFinishing else { return }
        cleanupAction = .save
        isFinishing = true
        defer { isFinishing = false }
        try? await photoModel?.discardUncommittedDetails()
        preservesDraftPhotos = false
        if returningHome { completeHomeNavigation() }
        else { onFinish() }
    }

    /// An older product's copy helper can cover an unfinished creation flow.
    /// Preserve that draft before dismissing either screen; a save failure is
    /// displayed by ExportView and leaves both the cover and draft in place.
    private func closeExport() throws {
        guard !isFinishing else { return }
        if let garment {
            if garment.informationCompletedAt != nil {
                try context.save()
                preservesDraftPhotos = false
            } else {
                let step: ProductDraftStep
                switch path.last {
                case .details: step = .details
                case .information, .completed: step = .information
                case nil: step = .measurementResult
                }
                try persistDraft(garment, step: step)
            }
        }
        returnsHomeAfterExport = true
        showFruits = false
        exportProduct = nil
    }

    private func finishExportDismissal() {
        guard returnsHomeAfterExport else { return }
        returnsHomeAfterExport = false
        if preservesDraftPhotos {
            // Retained originals belong to the saved draft, not temporary
            // cleanup. The root only changes navigation state.
            completeHomeNavigation()
        } else {
            Task { await finishFlow(returningHome: true) }
        }
    }

    private func completeHomeNavigation() {
        if let returnHomeFromExport { returnHomeFromExport() }
        else { onCancel() }
    }

    private func requestSaveAndExit() {
        Task { await saveAndExit() }
    }

    private func presentExitConfirmation(_ saveAction: @escaping () -> Void) {
        guard !isFinishing, pendingExitAction == nil else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        pendingExitAction = saveAction
    }

    private func requestDraftExit() {
        presentExitConfirmation(requestSaveAndExit)
    }

    private func confirmDraftExit() {
        guard !isFinishing, let saveAction = pendingExitAction else { return }
        pendingExitAction = nil
        saveAction()
    }

    private func saveAndExit() async {
        guard !isFinishing else { return }
        cleanupAction = .save
        isFinishing = true
        defer { isFinishing = false }
        do {
            guard let garment else { onCancel(); return }
            let step: ProductDraftStep
            switch path.last {
            case .details: step = .details
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

    private func requestDiscardAndExit() {
        guard !isFinishing else { return }
        pendingExitAction = nil
        Task { await discardAndExit() }
    }

    private func discardAndExit() async {
        guard !isFinishing else { return }
        cleanupAction = .discard
        isFinishing = true
        defer { isFinishing = false }
        do {
            if let garment {
                guard garment.informationCompletedAt == nil, garment.isCreationDraft else {
                    cleanupError = "등록을 마친 상품은 보관함에서 삭제해 주세요."
                    return
                }
                // Collect this flow's unsaved imports before the separate
                // deletion context invalidates the durable draft. A failed
                // deletion keeps those user edits and their files available.
                let uncommittedFiles = ProductPhotoImportStore.uncommittedFileURLs(for: garment, in: context)
                try GarmentStore.deleteSavedGarment(id: garment.id, in: context.container)
                ProductPhotoImportStore.removeUncommittedFiles(uncommittedFiles)
            }
        } catch {
            cleanupError = error.localizedDescription
            return
        }
        garment = nil
        preservesDraftPhotos = false
        // The durable deletion is complete. Failed temporary-file cleanup can retry on dismissal.
        try? await photoModel?.discardUncommittedDetails()
        onDraftDiscarded()
    }

    private func persistDraft(_ garment: Garment, step: ProductDraftStep) throws {
        if step == .information, !synchronizeInformationPhotoSelection() { throw ProductDraftStore.DraftError.invalidPhotos }
        // Revisiting capture after completion keeps this a saved product.
        if garment.informationCompletedAt != nil {
            try context.save()
            preservesDraftPhotos = false
            return
        }
        guard let measurementRecordID else { throw CameraFailure.mismatchedCapture }
        let inputData = try JSONEncoder().encode(measurementInput)
        try ProductDraftStore.save(garment: garment, step: step, measurementRecordID: measurementRecordID,
            photoModel: photoModel, measurementInputData: inputData,
            aiReviewNotes: autofillReviewNotes, usesProductAutofill: usesProductAutofill, in: context)
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
            try await preparePhotoSession(for: saved, record: record, snapshot: draft.photoState)
            if let data = draft.measurementInputData {
                measurementInput = try JSONDecoder().decode(GarmentMeasurementInputState.self, from: data)
            }
            garment = saved
            autofillReviewNotes = draft.aiReviewNotes ?? []
            usesProductAutofill = draft.usesProductAutofill ?? true
            measurementRecordID = record.id
            restoredRecord = record
            switch draft.step {
            case .measurementResult: path = []
            // Decode legacy selection drafts without deleting their captures.
            case .details, .photoSelection: path = [.details]
            case .information: path = [.details, .information]
            }
        } catch {
            restorationError = "저장한 작업은 보관함에 남아 있어요. \(error.localizedDescription)"
        }
        isRestoring = false
    }
}
