import SwiftUI
import UIKit

enum ProductInformationStyle {
    static let background = Color(.systemBackground)
    static let field = Color("BrandNeutral50")
    static let accent = Color("BrandMain500")
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
    var showsPhotoSection = true
    var onPhotoImportingChange: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            if showsPhotoSection {
                ProductInputPhotoSection(garment: garment, allowsEditing: allowsPhotoEditing,
                                         onImportingChange: onPhotoImportingChange)
            }
            ProductInputField(title: "제품명", text: $garment.name,
                placeholder: "업로드에 사용되는 제품명을 입력해주세요", identifier: "name", isRequired: true,
                isSingleLine: !allowsPhotoEditing, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isNameValid(garment)
                    ? "제품명을 입력해주세요" : nil)
            ProductInputField(title: "상세 설명", text: $garment.detail,
                placeholder: "제품의 상세 설명을 입력해주세요",
                identifier: "detail", isRequired: true, isMultiline: true, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isDetailValid(garment)
                    ? "설명을 입력해주세요" : nil)
            ProductPriceField(garment: garment, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isPriceValid(garment)
                    ? "가격을 입력해주세요" : nil)
            ProductInputField(title: "브랜드", text: $garment.brand,
                placeholder: "브랜드를 입력해주세요", identifier: "brand", usesEditingLayout: allowsPhotoEditing)
            ProductMeasurementInputTable(garment: garment, measurementInput: $measurementInput, focus: focus, usesEditingLayout: allowsPhotoEditing)
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
                Text("*").foregroundStyle(Color("BrandMain500")).accessibilityHidden(true)
            }
        }
        .font(.custom("Pretendard-SemiBold", size: 17, relativeTo: .headline))
        .tracking(-0.43)
        .foregroundStyle(Color("BrandNeutralBlack"))
        .accessibilityLabel(title + (isRequired ? ", 필수" : ""))
    }
}

struct ProductInputField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var isRequired = false
    var isSingleLine = false
    var isMultiline = false
    var usesEditingLayout = false
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductFieldTitle(title: title, isRequired: isRequired)
                .frame(minHeight: usesEditingLayout ? 22 : nil, alignment: .leading)
            ProductFieldEditor(text: $text, placeholder: placeholder, isSingleLine: isSingleLine,
                               isMultiline: isMultiline, usesEditingLayout: usesEditingLayout)
                .font(.custom("Pretendard-Regular", size: 15, relativeTo: .subheadline))
                .tracking(-0.23)
                .foregroundStyle(Color("BrandNeutralBlack"))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(minHeight: isMultiline ? 204 : 52, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ProductInformationStyle.field, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if errorMessage != nil {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(ProductInformationStyle.error, lineWidth: 1)
                    }
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier("product-info.\(identifier)")
                .productInputInteractionArea()
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(.caption))
                    .foregroundStyle(ProductInformationStyle.error)
                    .accessibilityIdentifier("product-info.\(identifier).error")
            }
        }
    }
}

private struct ProductFieldEditor: View {
    @Binding var text: String
    let placeholder: String
    let isSingleLine: Bool
    let isMultiline: Bool
    let usesEditingLayout: Bool
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15

    var body: some View {
        if isMultiline && usesEditingLayout {
            EditingDescriptionTextView(text: $text, fontSize: fontSize)
                .frame(height: 172)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(Color("BrandNeutral300"))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else if isMultiline {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .contentMargins(.all, 0)
                .padding(.horizontal, -5)
                .padding(.vertical, -8)
                .frame(height: 172)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(Color("BrandNeutral300"))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else if isSingleLine {
            TextField("", text: $text, prompt: prompt)
        } else {
            TextField("", text: $text, prompt: prompt, axis: .vertical)
                .lineLimit(1...2)
                .multilineTextAlignment(.leading)
                .lineSpacing(usesEditingLayout ? max(0, 20 * fontSize / 15 - inputFont.lineHeight) : 0)
                .padding(.vertical, usesEditingLayout ? max(0, 20 * fontSize / 15 - inputFont.lineHeight) / 2 : 0)
        }
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(Color("BrandNeutral300"))
    }

    private var inputFont: UIFont {
        UIFont(name: "Pretendard-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

}

/// TextEditor does not consistently apply SwiftUI tracking to editable text.
/// Specify the paragraph metrics on the backing text itself, without compensating insets.
private struct EditingDescriptionTextView: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textAlignment = .left
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard view.markedTextRange == nil else { return }
        let attributes = textAttributes
        if view.text != text || context.coordinator.appliedFontSize != fontSize {
            let selection = view.selectedRange
            let offset = view.contentOffset
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            view.selectedRange = NSRange(location: min(selection.location, view.text.utf16.count), length: 0)
            view.setContentOffset(offset, animated: false)
            context.coordinator.appliedFontSize = fontSize
        }
        view.typingAttributes = attributes
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.minimumLineHeight = 20 * fontSize / 15
        paragraph.maximumLineHeight = 20 * fontSize / 15
        paragraph.paragraphSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: UIFont(name: "Pretendard-Regular", size: fontSize) ?? UIFont.systemFont(ofSize: fontSize),
                .kern: -0.23 * fontSize / 15,
                .foregroundColor: UIColor(named: "BrandNeutralBlack") ?? UIColor.label,
                .paragraphStyle: paragraph]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditingDescriptionTextView
        var appliedFontSize: CGFloat?
        init(_ parent: EditingDescriptionTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            textView.typingAttributes = parent.textAttributes
        }
    }
}

struct ProductPriceField: View {
    @Bindable var garment: Garment
    var usesEditingLayout = false
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductFieldTitle(title: "가격", isRequired: true)
                .frame(minHeight: usesEditingLayout ? 22 : nil, alignment: .leading)
            ProductPriceInput(price: $garment.price)
                .productInputInteractionArea()
                .background(ProductInformationStyle.field, in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    if errorMessage != nil {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(ProductInformationStyle.error, lineWidth: 1)
                    }
                }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(.caption))
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
        HStack(spacing: 10) {
            Text(priceText.isEmpty ? "제품 가격" : priceText)
                .font(.custom("Pretendard-SemiBold", size: 15, relativeTo: .subheadline))
                .hidden()
                .padding(.trailing, 2)
                .overlay {
                    TextField("", text: $priceText, prompt: Text("제품 가격").foregroundStyle(Color("BrandNeutral300")))
                        .font(.custom("Pretendard-SemiBold", size: 15, relativeTo: .subheadline))
                        .keyboardType(.numberPad)
                        .focused($isFocused)
                        .accessibilityLabel("가격, 원")
                        .accessibilityHint("제품의 판매 가격을 입력해주세요")
                        .accessibilityIdentifier("product-info.price")
                }
            Text("원")
                .font(.custom("Pretendard-Regular", size: 15, relativeTo: .subheadline))
                .foregroundStyle(Color("BrandNeutral700"))
                .accessibilityIdentifier("product-info.price.unit")
            Spacer(minLength: 0)
        }
        .font(.custom("Pretendard-Regular", size: 15, relativeTo: .subheadline))
        .tracking(-0.23)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: 52)
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
