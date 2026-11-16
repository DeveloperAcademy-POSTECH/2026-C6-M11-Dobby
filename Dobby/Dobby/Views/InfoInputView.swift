//
//  InfoInputView.swift
//  Dobby
//
//  Created by 오하나 on 10/1/26.
//

import SwiftData
import SwiftUI
import UIKit

struct InfoInputView: View {
    @Bindable var garment: Garment
    let onExit: (() -> Void)?
    let allowsPhotoEditing: Bool
    var onComplete: ((Garment) -> Void)? = nil
    private let onGenerateAI: (() async throws -> Void)?
    private let onCancelGeneration: () -> Void
    private let onAIGenerationPresentationChange: ((ProductAutofillLoadingPresentation?) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.returnFromExport) private var returnFromExport

    @State private var exportProduct: ExportProduct?
    @State private var showFruits = false
    @State private var localMeasurementInput = GarmentMeasurementInputState()
    private let retainedMeasurementInput: Binding<GarmentMeasurementInputState>?
    @State private var saveError: String?
    @State private var hasAttemptedCompletion = false
    @State private var pendingExportDestination: ExportReturnDestination?
    @State private var isImportingPhotos = false
    @State private var generationRequestID: UUID?
    @State private var generationError: String?
    @FocusState private var focusedInformationField: ProductInformationField?
    @FocusState private var focusedMeasurementID: UUID?
    static let measurementTableID = "product-info.measurement-table"

    init(garment: Garment, measurementInput: Binding<GarmentMeasurementInputState>? = nil,
         allowsPhotoEditing: Bool = false,
         onExit: (() -> Void)? = nil,
         onGenerateAI: (() async throws -> Void)? = nil,
         onCancelGeneration: @escaping () -> Void = {},
         onAIGenerationPresentationChange: ((ProductAutofillLoadingPresentation?) -> Void)? = nil,
         onComplete: ((Garment) -> Void)? = nil) {
        self.garment = garment
        self.retainedMeasurementInput = measurementInput
        self.allowsPhotoEditing = allowsPhotoEditing
        self.onExit = onExit
        self.onComplete = onComplete
        self.onGenerateAI = onGenerateAI
        self.onCancelGeneration = onCancelGeneration
        self.onAIGenerationPresentationChange = onAIGenerationPresentationChange
    }

    private var measurementInput: Binding<GarmentMeasurementInputState> {
        retainedMeasurementInput ?? $localMeasurementInput
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    VStack(alignment: .leading, spacing: 24) {
                        ProductInputPhotoSection(garment: garment, allowsEditing: allowsPhotoEditing,
                            onImportingChange: { isImportingPhotos = $0 })
                            .productInputInteractionArea()
                        if onGenerateAI != nil { generateInformationButton.productInputInteractionArea() }
                    }
                    // Keep the same photo strip mounted and visible during generation.
                    // Only the editable information is covered by placeholders.
                    ZStack(alignment: .topLeading) {
                        ProductInformationFields(garment: garment, measurementInput: measurementInput,
                            focus: $focusedMeasurementID, informationFocus: $focusedInformationField,
                            showsValidationErrors: hasAttemptedCompletion,
                            allowsPhotoEditing: allowsPhotoEditing, showsPhotoSection: false,
                            onPhotoImportingChange: { isImportingPhotos = $0 })
                            .opacity(generationRequestID == nil ? 1 : 0)
                            .accessibilityHidden(generationRequestID != nil)

                        if generationRequestID != nil {
                            ProductInformationSkeletonView(measurementColumnCount: garment.visibleMeasurements.count)
                        }
                    }
                }
                    .disabled(generationRequestID != nil || isImportingPhotos)
                    .padding(.horizontal, 20)
                    .padding(.top, allowsPhotoEditing ? 32 : 26)
                    .padding(.bottom, 16)
                    .backgroundPreferenceValue(ProductInputInteractionBounds.self) { bounds in
                        ProductInputKeyboardDismissBackground(bounds: bounds, onDismiss: dismissKeyboard)
                    }
            }
            .backgroundPreferenceValue(ProductInputInteractionBounds.self) { bounds in
                ProductInputKeyboardDismissBackground(bounds: bounds, onDismiss: dismissKeyboard)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedMeasurementID) { _, _ in
                revealFocusedInput(using: proxy)
            }
            .onChange(of: focusedInformationField) { _, _ in
                revealFocusedInput(using: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // Wait for the resized visible area as well as the focus event.
                if focusedInformationField != .detail {
                    revealFocusedInput(using: proxy)
                }
            }
        }
        .background(ProductInformationStyle.background)
        .navigationTitle(allowsPhotoEditing ? "제품 정보 수정" : "제품 정보 입력")
        .productCreationProgress(allowsPhotoEditing ? nil : .information)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(onExit != nil)
        .toolbarBackground(ProductInformationStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.primary)
        .onDisappear {
            focusedInformationField = nil
            focusedMeasurementID = nil
            if generationRequestID != nil { cancelGeneration() }
        }
        .toolbar {
            if let onExit {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismissKeyboard()
                        onExit()
                    } label: {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(.black)
                    }
                    .tint(.black)
                    .disabled(generationRequestID != nil || isImportingPhotos)
                    .accessibilityLabel("뒤로가기")
                    .accessibilityIdentifier("product-flow.back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: complete) {
                    Text("완료")
                        .font(.system(.headline, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 61, height: 44)
                        .background(ProductInformationStyle.accent, in: Capsule())
                }
                .disabled(generationRequestID != nil || isImportingPhotos)
                .buttonStyle(.plain)
                .accessibilityIdentifier("product-info.done")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // 내보내기 화면은 자체 NavigationStack과 닫기 버튼을 갖고 있어 시트로 띄운다.
        .sheet(item: $exportProduct, onDismiss: finishExportDismissal) { product in
            ExportView(product: product, showFruits: $showFruits) { destination in
                try modelContext.save()
                pendingExportDestination = destination
                showFruits = false
                exportProduct = nil
            }
        }
        .alert("제품 정보를 저장하지 못했어요", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("확인", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "입력한 정보는 화면에 남아 있어요. 다시 시도해 주세요.")
                .accessibilityIdentifier("product-info.save-error")
        }
        .task(id: generationRequestID) {
            guard let identifier = generationRequestID, let onGenerateAI else { return }
            var failure: String?
            do {
                try await onGenerateAI()
            } catch {
                if generationRequestID == identifier, !(error is CancellationError), !Task.isCancelled {
                    failure = error.localizedDescription
                }
            }
            if generationRequestID == identifier {
                generationRequestID = nil
                onAIGenerationPresentationChange?(nil)
                generationError = failure
            }
        }
        .alert("AI 정보를 생성하지 못했어요", isPresented: Binding(
            get: { generationError != nil }, set: { if !$0 { generationError = nil } }
        )) {
            Button("다시 시도", action: requestGeneration)
                .accessibilityIdentifier("product-ai.retry")
            Button("직접 입력", role: .cancel) { generationError = nil }
                .accessibilityIdentifier("product-ai.manual")
        } message: {
            Text(generationError ?? "잠시 후 다시 시도하거나 직접 입력해 주세요.")
        }
        .overlay {
            if generationRequestID != nil, onAIGenerationPresentationChange == nil {
                ProductAutofillLoadingView(onCancel: cancelGeneration)
            }
        }
    }

    private var generateInformationButton: some View {
        Button(action: requestGeneration) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .frame(height: 20)
                Text(garment.aiInformationGeneratedAt == nil
                    ? "AI로 제품 정보 생성하기" : "다시 정보 생성하기")
                    .tracking(allowsPhotoEditing ? -0.16 : -0.31)

            }
            .font(.custom(allowsPhotoEditing ? "Pretendard-Medium" : "Pretendard-SemiBold", size: 16, relativeTo: .callout))
            .foregroundStyle(Color("BrandMain500"))
            .frame(maxWidth: .infinity, minHeight: 20)
            .padding(.horizontal, 8)
            .padding(.vertical, 15)
            .background(Color("BrandMain50"), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(generationRequestID != nil || isImportingPhotos)
        .accessibilityHint("선택한 제품 사진으로 제품명, 설명, 브랜드를 생성합니다")
        .accessibilityIdentifier("product-ai.generate")
    }

    private func requestGeneration() {
        guard generationRequestID == nil, !isImportingPhotos, onGenerateAI != nil else { return }
        dismissKeyboard()
        generationError = nil
        generationRequestID = UUID()
        onAIGenerationPresentationChange?(ProductAutofillLoadingPresentation(onCancel: cancelGeneration))
    }

    private func cancelGeneration() {
        onCancelGeneration()
        generationRequestID = nil
        onAIGenerationPresentationChange?(nil)
    }

    private func complete() {
        guard generationRequestID == nil, !isImportingPhotos else { return }
        hasAttemptedCompletion = true
        guard GarmentInformationValidation.isValid(garment) else { return }
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &measurementInput.wrappedValue.drafts,
                                           isEditingExistingProduct: allowsPhotoEditing) {
                try modelContext.save()
            }
            // End editing before navigation so returning from export doesn't
            // restore a decimal keyboard for a field outside the visible area.
            focusedInformationField = nil
            focusedMeasurementID = nil
            if let onComplete {
                onComplete(garment)
            } else {
                pendingExportDestination = nil
                showFruits = false
                exportProduct = ExportProduct(garment: garment)
            }
        } catch {
            if let validation = error as? GarmentInputCompletion.ValidationError {
                saveError = validation.localizedDescription
            } else {
                saveError = "입력한 정보는 화면에 남아 있어요. 잠시 후 다시 저장해 주세요."
            }
        }
    }

    private func finishExportDismissal() {
        guard let destination = pendingExportDestination else { return }
        pendingExportDestination = nil
        returnFromExport?(to: destination)
    }

    private func revealFocusedInput(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            if let focusedInformationField, focusedInformationField != .detail {
                proxy.scrollTo(focusedInformationField)
            } else if focusedMeasurementID != nil {
                proxy.scrollTo(Self.measurementTableID, anchor: .bottom)
            }
        }
    }

    private func dismissKeyboard() {
        focusedInformationField = nil
        focusedMeasurementID = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

}

/// The visible text outlives its dirty draft. Clearing a consumed draft must not
/// switch a focused TextField back to a rounded model display and emit that
/// rounded value as a new edit during navigation/keyboard dismissal.
nonisolated struct GarmentMeasurementInputState: Codable, Equatable {
    private var inputTexts: [UUID: String] = [:]
    var drafts: [UUID: String] = [:]

    @MainActor
    func text(for value: MeasuredValue) -> String {
        inputTexts[value.id] ?? GarmentMeasurementInputText.format(value.valueCm)
    }

    @MainActor
    mutating func setText(_ text: String, for value: MeasuredValue) {
        guard text != self.text(for: value) else { return }
        inputTexts[value.id] = text
        drafts[value.id] = text
    }
}

/// A draft exists only after typing. Formatting and repeated focus loss never
/// write a rounded display value back into the automatic measurement.
@MainActor
enum GarmentMeasurementInputText {
    static func hasUsableValue(_ value: MeasuredValue, drafts: [UUID: String]) -> Bool {
        // An unfinished text edit is a form-validation concern, not evidence
        // that the already calculated automatic measurement has failed.
        if value.valueCm.isFinite && value.valueCm > 0 { return true }
        if let draft = drafts[value.id] { return parsed(draft) != nil }
        return false
    }

    static func parsed(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    static func commitDraft(for value: MeasuredValue, drafts: inout [UUID: String]) {
        guard let text = drafts[value.id], let entered = parsed(text) else { return }
        // Invalid input remains editable; completion reports it instead of
        // silently discarding the user's text or exporting an older value.
        drafts.removeValue(forKey: value.id)
        value.update(to: entered)
    }

    static func format(_ cm: Double) -> String {
        guard cm.isFinite, cm > 0 else { return "" }
        return MeasurementDisplayText.centimeters(cm)
    }
}

@MainActor
enum GarmentInputCompletion {
    nonisolated enum ValidationError: LocalizedError, Sendable {
        case invalidMeasurement(String)
        case missingInformation(String)

        var errorDescription: String? {
            switch self {
            case .missingInformation(let label):
                return "\(label)을(를) 올바르게 입력해 주세요."
            case .invalidMeasurement(let label):
                return "\(label)에 0보다 큰 숫자를 입력해 주세요. 입력한 정보는 화면에 남아 있어요."
            }
        }
    }

    /// Validate all visible fields before modifying any of them. A failed database save
    /// retains the edits in the context, so retrying does not lose typed values.
    static func save(garment: Garment, drafts: inout [UUID: String],
                     isEditingExistingProduct: Bool = false,
                     persist: () throws -> Void) throws {
        // Hidden bilateral evidence stays untouched. An invalid hidden left
        // observation must not block editing and saving the usable right one.
        try GarmentInformationValidation.validate(garment)
        let measurements = garment.visibleMeasurements
        for value in measurements {
            let entered = drafts[value.id].flatMap { GarmentMeasurementInputText.parsed($0) }
            if drafts[value.id] != nil && entered == nil {
                throw ValidationError.invalidMeasurement(value.displayLabel)
            }
            let accepted = entered ?? value.valueCm
            guard accepted.isFinite, accepted > 0 else {
                throw ValidationError.invalidMeasurement(value.displayLabel)
            }
        }
        for value in measurements {
            GarmentMeasurementInputText.commitDraft(for: value, drafts: &drafts)
        }
        let valuesBeforeStorage = garment.measurements.map { ($0, $0.valueCm) }
        for value in garment.measurements where value.valueCm.isFinite && value.valueCm > 0 {
            value.valueCm = StoredMeasurementValue.centimeters(value.valueCm)
        }
        garment.syncFilterFields()
        let previousCompletion = garment.informationCompletedAt
        let previousDraft = garment.creationDraftData
        // Completing a resumed draft registers it now. Later edits preserve that
        // first completion, including the creation-date fallback for legacy products.
        garment.informationCompletedAt = previousCompletion
            ?? (isEditingExistingProduct ? garment.createdAt : .now)
        garment.creationDraftData = nil
        do {
            try persist()
        } catch {
            // Truncation belongs to successful persistence. Keep the user's
            // full input available for a retry when storage fails.
            for (value, previousValue) in valuesBeforeStorage {
                value.valueCm = previousValue
            }
            garment.syncFilterFields()
            garment.informationCompletedAt = previousCompletion
            garment.creationDraftData = previousDraft
            throw error
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        InfoInputView(garment: SampleData.first(in: SampleData.previewContainer.mainContext))
    }
    .modelContainer(SampleData.previewContainer)
}
#endif
