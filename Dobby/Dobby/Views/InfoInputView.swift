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

    @Environment(\.modelContext) private var modelContext

    @State private var exportProduct: ExportProduct?
    @State private var copyController = CopyActivityController()
    @State private var showFruits = false
    @State private var localMeasurementInput = GarmentMeasurementInputState()
    private let retainedMeasurementInput: Binding<GarmentMeasurementInputState>?
    @State private var saveError: String?
    @State private var hasAttemptedCompletion = false
    @FocusState private var focusedMeasurementID: UUID?
    static let measurementTableID = "product-info.measurement-table"

    init(garment: Garment, measurementInput: Binding<GarmentMeasurementInputState>? = nil,
         allowsPhotoEditing: Bool = false,
         onExit: (() -> Void)? = nil,
         onComplete: ((Garment) -> Void)? = nil) {
        self.garment = garment
        self.retainedMeasurementInput = measurementInput
        self.allowsPhotoEditing = allowsPhotoEditing
        self.onExit = onExit
        self.onComplete = onComplete
    }

    private var measurementInput: Binding<GarmentMeasurementInputState> {
        retainedMeasurementInput ?? $localMeasurementInput
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ProductInformationFields(garment: garment, measurementInput: measurementInput,
                    focus: $focusedMeasurementID, showsValidationErrors: hasAttemptedCompletion,
                    allowsPhotoEditing: allowsPhotoEditing)
                    .padding(.horizontal, 20)
                    .padding(.top, allowsPhotoEditing ? 12 : 16)
                    .padding(.bottom, 16)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismissKeyboard)
                    }
            }
            .background {
                ProductInformationStyle.background
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissKeyboard)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: focusedMeasurementID) { _, _ in
                revealMeasurements(using: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                // Wait for the resized visible area as well as the focus event.
                // The decimal field must stay above the software keyboard.
                revealMeasurements(using: proxy)
            }
        }
        .background(ProductInformationStyle.background)
        .navigationTitle(allowsPhotoEditing ? "제품 정보 수정" : "제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(onExit != nil)
        .toolbarBackground(ProductInformationStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.primary)
        .onDisappear { focusedMeasurementID = nil }
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
                    .accessibilityLabel("뒤로가기")
                    .accessibilityIdentifier("product-flow.back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: complete) {
                    Text("완료")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 61, height: 44)
                        .background(GarmentInformationValidation.isValid(garment)
                            ? ProductInformationStyle.accent : ProductInformationStyle.accentSoft,
                            in: Capsule())
                }
                .disabled(!GarmentInformationValidation.hasAnyInformation(garment))
                .buttonStyle(.plain)
                .accessibilityIdentifier("product-info.done")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // 내보내기 화면은 자체 NavigationStack과 닫기 버튼을 갖고 있어 시트로 띄운다.
        .sheet(item: $exportProduct) { product in
            ExportView(product: product, controller: copyController, showFruits: $showFruits)
        }
        .alert("제품 정보를 저장하지 못했어요", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("확인", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "입력한 정보는 화면에 남아 있어요. 다시 시도해 주세요.")
                .accessibilityIdentifier("product-info.save-error")
        }
    }

    private func complete() {
        hasAttemptedCompletion = true
        guard GarmentInformationValidation.isValid(garment) else { return }
        do {
            try GarmentInputCompletion.save(garment: garment, drafts: &measurementInput.wrappedValue.drafts) {
                try modelContext.save()
            }
            // End editing before navigation so returning from export doesn't
            // restore a decimal keyboard for a field outside the visible area.
            focusedMeasurementID = nil
            if let onComplete {
                onComplete(garment)
            } else {
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

    private func revealMeasurements(using proxy: ScrollViewProxy) {
        guard focusedMeasurementID != nil else { return }
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo(Self.measurementTableID, anchor: .bottom)
        }
    }

    private func dismissKeyboard() {
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
        garment.informationCompletedAt = .now
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
