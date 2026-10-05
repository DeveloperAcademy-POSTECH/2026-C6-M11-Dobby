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
    var onComplete: ((Garment) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext

    @State private var exportProduct: ExportProduct?
    @State private var copyController = CopyActivityController()
    @State private var showFruits = false
    @State private var localMeasurementInput = GarmentMeasurementInputState()
    private let retainedMeasurementInput: Binding<GarmentMeasurementInputState>?
    @State private var saveError: String?
    @FocusState private var focusedMeasurementID: UUID?
    private static let measurementTableID = "product-info.measurement-table"
    /// 표의 테두리와 칸 사이 선. 같은 선이므로 한 곳에서 정한다.
    private static let tableLine = Color(.separator).opacity(0.5)
    /// 이보다 많으면 고르게 나누지 않고 가로로 민다.
    private static let evenlyFittingColumns = 5

    init(garment: Garment, measurementInput: Binding<GarmentMeasurementInputState>? = nil,
         onComplete: ((Garment) -> Void)? = nil) {
        self.garment = garment
        self.retainedMeasurementInput = measurementInput
        self.onComplete = onComplete
    }

    private var measurementInput: Binding<GarmentMeasurementInputState> {
        retainedMeasurementInput ?? $localMeasurementInput
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    photoStrip
                    field("제품 명", text: $garment.name,
                          placeholder: "예: 90s 나이키 자켓", lines: 1...2, identifier: "name")
                    field("설명", text: $garment.detail,
                          placeholder: "연식, 실착 사이즈, 상태를 적어주세요", lines: 5...10, identifier: "detail")
                    field("브랜드", text: $garment.brand,
                          placeholder: "예: 나이키", lines: 1...1, identifier: "brand")
                    sizeTable.id(Self.measurementTableID)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
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
        .navigationTitle("제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { focusedMeasurementID = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("완료", action: complete)
                .fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityIdentifier("product-info.done")
            }
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

    // MARK: 제품 사진

    private var photoStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("제품 사진").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(garment.productPhotos) { photo in
                        thumbnail(photo)
                    }
                }
                .padding(.horizontal, 20)
            }
            // 사진이 화면 가장자리까지 이어져 보이도록 바깥 여백을 상쇄한다.
            .padding(.horizontal, -20)
        }
    }

    private func thumbnail(_ photo: GarmentPhoto) -> some View {
        StoredProductPhotoView(photo: photo, maximumPixelSize: 320)
            .frame(width: 92, height: 108).clipped()
    }

    // MARK: 글자 입력

    private func field(_ title: String, text: Binding<String>,
                       placeholder: String, lines: ClosedRange<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            TextField(placeholder, text: text, axis: .vertical)
                .accessibilityIdentifier("product-info.\(identifier)")
                .lineLimit(lines)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: 실측 사이즈

    /// 항목을 가로로 늘어놓는 표. 바지는 항목이 여덟 개라 화면을 넘기므로 가로 스크롤을 둔다.
    private var sizeTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("실측 사이즈").font(.headline)
            let uncertain = garment.orderedMeasurements.filter {
                $0.sourceStatusRaw == MeasurementStatus.uncertain.rawValue && !$0.isEdited
            }
            if !uncertain.isEmpty {
                Label("\(uncertain.map(\.label).joined(separator: ", ")): 자동 측정값을 확인해 주세요.",
                      systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("product-info.measurement-warning")
            }
            // 다섯 칸까지는 화면 폭을 고르게 나눠 갖고, 그보다 많으면 가로로 민다.
            // 바지는 항목이 여덟 개라 고르게 나누면 한 칸이 "56.5" 를 못 담는다.
            let columns = garment.orderedMeasurements
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, value in
                        if index > 0 {
                            Rectangle().fill(Self.tableLine).frame(width: 1)
                        }
                        SizeColumn(value: value, text: Binding(
                            get: { measurementInput.wrappedValue.text(for: value) },
                            set: { measurementInput.wrappedValue.setText($0, for: value) }
                        ), focus: $focusedMeasurementID)
                        .frame(maxWidth: columns.count <= Self.evenlyFittingColumns ? .infinity : nil)
                    }
                }
                .frame(minWidth: columns.count <= Self.evenlyFittingColumns
                       ? UIScreen.main.bounds.width - 40 : nil)
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollDisabled(columns.count <= Self.evenlyFittingColumns)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).stroke(Self.tableLine, lineWidth: 1)
            }
            .accessibilityIdentifier("product-info.measurements")
        }
    }
}

// MARK: - 치수 한 칸

/// 위에 항목 이름, 아래에 값. 값을 누르면 바로 고칠 수 있다.
///
/// 목업에는 연필이 없지만 편집은 남겨 두었다. 눌러서 고치는 것이 화면을 더 늘리지 않으면서
/// 숫자가 틀렸을 때 바로 손볼 수 있는 길이기 때문이다.
private struct SizeColumn: View {
    @Bindable var value: MeasuredValue

    @Binding var text: String
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        VStack(spacing: 0) {
            Text(value.label)
                .font(.subheadline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))

            HStack(spacing: 1) {
                TextField("", text: $text)
                    .accessibilityLabel("\(value.label) 센티미터")
                    .accessibilityIdentifier("product-info.measurement.\(value.key)")
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .focused(focus, equals: value.id)
                    .fixedSize()
                    .monospacedDigit()
                Text("cm").font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 84)
    }
}

/// The visible text outlives its dirty draft. Clearing a consumed draft must not
/// switch a focused TextField back to a rounded model display and emit that
/// rounded value as a new edit during navigation/keyboard dismissal.
@MainActor
struct GarmentMeasurementInputState {
    private var inputTexts: [UUID: String] = [:]
    var drafts: [UUID: String] = [:]

    func text(for value: MeasuredValue) -> String {
        inputTexts[value.id] ?? GarmentMeasurementInputText.format(value.valueCm)
    }

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
        guard cm.isFinite else { return "" }
        return MeasurementDisplayText.centimeters(cm)
    }
}

@MainActor
enum GarmentInputCompletion {
    nonisolated enum ValidationError: LocalizedError, Sendable {
        case invalidMeasurement(String)

        var errorDescription: String? {
            switch self {
            case .invalidMeasurement(let label):
                return "\(label)에 0보다 큰 숫자를 입력해 주세요. 입력한 정보는 화면에 남아 있어요."
            }
        }
    }

    /// Validate all fields before modifying any of them. A failed database save
    /// retains the edits in the context, so retrying does not lose typed values.
    static func save(garment: Garment, drafts: inout [UUID: String],
                     persist: () throws -> Void) throws {
        let measurements = garment.orderedMeasurements
        for value in measurements {
            let entered = drafts[value.id].flatMap { GarmentMeasurementInputText.parsed($0) }
            if drafts[value.id] != nil && entered == nil {
                throw ValidationError.invalidMeasurement(value.label)
            }
            let accepted = entered ?? value.valueCm
            guard accepted.isFinite, accepted > 0 else {
                throw ValidationError.invalidMeasurement(value.label)
            }
        }
        for value in measurements {
            GarmentMeasurementInputText.commitDraft(for: value, drafts: &drafts)
        }
        garment.syncFilterFields()
        let previousCompletion = garment.informationCompletedAt
        garment.informationCompletedAt = .now
        do {
            try persist()
        } catch {
            // Keep the user's edits for retry, while a failed save must not
            // promote a draft to a completed product in the current context.
            garment.informationCompletedAt = previousCompletion
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
