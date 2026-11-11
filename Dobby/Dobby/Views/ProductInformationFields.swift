import SwiftUI

enum ProductInformationStyle {
    static let background = Color(.systemBackground)
    static let field = Color(red: 242 / 255, green: 241 / 255, blue: 240 / 255)
    static let accent = Color(red: 237 / 255, green: 77 / 255, blue: 41 / 255)
    static let accentSoft = Color("BrandMain300")
    static let upload = Color("BrandMain500")
    static let error = Color("AccentsRed")

    static func measurements(for garment: Garment) -> [MeasuredValue] {
        guard garment.group == .top else { return garment.visibleMeasurements }
        let keys = ["shoulderWidth", "chestWidth", "totalLength", "frontLength", "sleeveLengthLeft", "sleeveLengthRight"]
        return garment.visibleMeasurements.enumerated().sorted { left, right in
            let leftOrder = keys.firstIndex(of: left.element.key) ?? keys.count
            let rightOrder = keys.firstIndex(of: right.element.key) ?? keys.count
            return leftOrder == rightOrder ? left.offset < right.offset : leftOrder < rightOrder
        }.map(\.element)
    }

    static func measurementTitle(for value: MeasuredValue) -> String {
        if value.key == "totalLength" { return "기장" }
        if value.key == "sleeveLengthLeft" || value.key == "sleeveLengthRight" { return "소매" }
        return GarmentMeasurementPresentation.productTitle(for: value.key, fallback: value.displayLabel)
    }

}

struct ProductInformationFields: View {
    @Bindable var garment: Garment
    @Binding var measurementInput: GarmentMeasurementInputState
    let focus: FocusState<UUID?>.Binding
    let showsValidationErrors: Bool
    var allowsPhotoEditing = false
    var onPhotoImportingChange: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ProductInputPhotoSection(garment: garment, allowsEditing: allowsPhotoEditing,
                                     onImportingChange: onPhotoImportingChange)
            ProductInputField(title: "제품명", text: $garment.name,
                placeholder: "업로드에 사용되는 제품명을 입력해주세요", identifier: "name", isRequired: true,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isNameValid(garment)
                    ? "제품명을 입력해주세요" : nil)
            ProductInputField(title: "설명", text: $garment.detail,
                placeholder: "제품의 설명을 입력해주세요\n(예: 제품 정보, 하자 여부, 어울리는 코디)",
                identifier: "detail", isRequired: true, isMultiline: true,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isDetailValid(garment)
                    ? "설명을 입력해주세요" : nil)
            ProductPriceField(garment: garment,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isPriceValid(garment)
                    ? "가격을 입력해주세요" : nil)
            ProductInputField(title: "브랜드", text: $garment.brand,
                placeholder: "제품의 브랜드를 적어주세요 (없다면 생략 가능)", identifier: "brand")
            ProductMeasurementInputTable(garment: garment, measurementInput: $measurementInput, focus: focus)
                .id(InfoInputView.measurementTableID)
        }
    }
}

struct ProductFieldTitle: View {
    let title: String
    var isRequired = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            if isRequired {
                Text("*").foregroundStyle(Color(uiColor: .systemRed)).accessibilityHidden(true)
            }
        }
        .font(.headline)
        .accessibilityLabel(title + (isRequired ? ", 필수" : ""))
    }
}

struct ProductInputField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var isRequired = false
    var isMultiline = false
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: title, isRequired: isRequired)
            ProductFieldEditor(text: $text, placeholder: placeholder, isMultiline: isMultiline)
                .font(.subheadline)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minHeight: isMultiline ? 176 : 56, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ProductInformationStyle.field, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if errorMessage != nil {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(ProductInformationStyle.error, lineWidth: 1)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier("product-info.\(identifier)")
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(ProductInformationStyle.error)
                    .accessibilityIdentifier("product-info.\(identifier).error")
            }
        }
    }
}

private struct ProductFieldEditor: View {
    @Binding var text: String
    let placeholder: String
    let isMultiline: Bool

    var body: some View {
        if isMultiline {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .contentMargins(.all, 0)
                .frame(height: 144)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else {
            TextField(placeholder, text: $text, axis: .vertical).lineLimit(1...2)
        }
    }
}

struct ProductPriceField: View {
    @Bindable var garment: Garment
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "가격", isRequired: true)
            ProductPriceInput(price: $garment.price)
                .background(ProductInformationStyle.field, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if errorMessage != nil {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(ProductInformationStyle.error, lineWidth: 1)
                    }
                }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(ProductInformationStyle.error)
                    .accessibilityIdentifier("product-info.price.error")
            }
        }
    }
}

private struct ProductPriceInput: View {
    @Binding var price: Int?
    @State private var priceText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(priceText.isEmpty ? " " : priceText)
                .font(.system(size: 16, weight: .medium))
                .hidden()
                .padding(.trailing, 2)
                .overlay {
                    TextField("", text: $priceText)
                        .font(.system(size: 16, weight: .medium))
                        .keyboardType(.numberPad)
                        .focused($isFocused)
                        .accessibilityLabel("가격, 원")
                        .accessibilityHint("제품의 판매 가격을 입력해주세요")
                        .accessibilityIdentifier("product-info.price")
                }
            Text("원")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(priceText.isEmpty ? 0 : 1)
                .accessibilityIdentifier("product-info.price.unit")
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .overlay(alignment: .leading) {
            if priceText.isEmpty && !isFocused {
                Text("제품의 판매 가격을 입력해주세요")
                    .font(.subheadline).foregroundStyle(.tertiary)
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { priceText = formatPrice(price) }
        .onChange(of: priceText) { _, text in updatePriceText(text) }
    }

    private func updatePriceText(_ text: String) {
        let digits = text.replacingOccurrences(of: ",", with: "")
        if digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            price = digits.isEmpty ? nil : Int(digits)
        }
        let formatted = formatPrice(price)
        guard formatted != text else { return }
        Task { @MainActor in
            await Task.yield()
            guard priceText == text else { return }
            priceText = formatted
        }
    }

    private func formatPrice(_ value: Int?) -> String {
        value.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) } ?? ""
    }
}
