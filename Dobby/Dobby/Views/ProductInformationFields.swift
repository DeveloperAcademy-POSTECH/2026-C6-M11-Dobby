import OSLog
import SwiftUI
import UIKit

enum ProductInformationField: Hashable {
    case name
    case detail
    case price
    case brand
}

enum ProductInformationStyle {
    static let background = Color(.systemBackground)
    static let field = Color("BrandNeutral50")
    static let accent = Color("BrandMain500")
    static let accentSoft = Color("BrandMain300")
    static let upload = Color("BrandMain500")
    static let error = Color("AccentsRed")

    static func measurements(for garment: Garment) -> [MeasuredValue] {
        guard garment.group == .top else { return garment.visibleMeasurements }
        let keys = ["totalLength", "shoulderWidth", "chestWidth", "frontLength", "sleeveLengthLeft", "sleeveLengthRight"]
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
    let informationFocus: FocusState<ProductInformationField?>.Binding
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
                placeholder: "업로드에 사용되는 제품명을 입력해주세요", identifier: "name",
                focus: informationFocus, focusValue: .name, isRequired: true,
                isSingleLine: !allowsPhotoEditing, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isNameValid(garment)
                    ? "제품명을 입력해주세요" : nil)
            ProductInputField(title: "상세 설명", text: $garment.detail,
                placeholder: "제품의 상세 설명을 입력해주세요",
                identifier: "detail", focus: informationFocus, focusValue: .detail,
                isRequired: true, isMultiline: true, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isDetailValid(garment)
                    ? "설명을 입력해주세요" : nil)
            ProductPriceField(garment: garment, focus: informationFocus, usesEditingLayout: allowsPhotoEditing,
                errorMessage: showsValidationErrors && !GarmentInformationValidation.isPriceValid(garment)
                    ? "가격을 입력해주세요" : nil)
            ProductInputField(title: "브랜드", text: $garment.brand,
                placeholder: "브랜드를 입력해주세요", identifier: "brand",
                focus: informationFocus, focusValue: .brand, usesEditingLayout: allowsPhotoEditing)
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
    let focus: FocusState<ProductInformationField?>.Binding
    let focusValue: ProductInformationField
    var isRequired = false
    var isSingleLine = false
    var isMultiline = false
    var usesEditingLayout = false
    var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductFieldTitle(title: title, isRequired: isRequired)
                .frame(minHeight: usesEditingLayout ? 22 : nil, alignment: .leading)
            ProductFieldEditor(text: $text, placeholder: placeholder, focus: focus, focusValue: focusValue,
                               isSingleLine: isSingleLine, isMultiline: isMultiline,
                               usesEditingLayout: usesEditingLayout)
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
        .id(focusValue)
    }
}

private struct ProductFieldEditor: View {
    @Binding var text: String
    let placeholder: String
    let focus: FocusState<ProductInformationField?>.Binding
    let focusValue: ProductInformationField
    let isSingleLine: Bool
    let isMultiline: Bool
    let usesEditingLayout: Bool
    @State private var descriptionHeight: CGFloat = 172
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15

    var body: some View {
        if isMultiline && usesEditingLayout {
            DescriptionTextView(text: $text, fontSize: fontSize, isScrollEnabled: true,
                                contentHeight: nil)
                .focused(focus, equals: focusValue)
                .frame(height: 172)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        prompt
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else if isMultiline {
            DescriptionTextView(text: $text, fontSize: fontSize, isScrollEnabled: false,
                                contentHeight: $descriptionHeight)
                .focused(focus, equals: focusValue)
                .frame(height: descriptionHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        prompt
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        } else if isSingleLine {
            TextField("", text: $text, prompt: prompt)
                .focused(focus, equals: focusValue)
        } else {
            TextField("", text: $text, prompt: prompt, axis: .vertical)
                .focused(focus, equals: focusValue)
                .lineLimit(1...2)
                .multilineTextAlignment(.leading)
                .lineSpacing(usesEditingLayout ? max(0, 20 * fontSize / 15 - inputFont.lineHeight) : 0)
                .padding(.vertical, usesEditingLayout ? max(0, 20 * fontSize / 15 - inputFont.lineHeight) / 2 : 0)
        }
    }

    private var prompt: Text {
        Text(placeholder)
            .font(.custom("Pretendard-Regular", size: 17, relativeTo: .body))
            .foregroundStyle(Color("BrandNeutral300"))
    }

    private var inputFont: UIFont {
        UIFont(name: "Pretendard-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize)
    }

}

/// Applies consistent typography to UIKit text editing. The registration field
/// expands and reports its caret, while the saved-product editor keeps scrolling.
private struct DescriptionTextView: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let isScrollEnabled: Bool
    let contentHeight: Binding<CGFloat>?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = isScrollEnabled
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textAlignment = .left
        view.adjustsFontForContentSizeCategory = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isScrollEnabled = isScrollEnabled
        guard view.markedTextRange == nil else { return }
        let attributes = textAttributes
        if view.text != text || context.coordinator.appliedFontSize != fontSize {
            let selection = view.selectedRange
            let offset = view.contentOffset
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            view.selectedRange = NSRange(location: min(selection.location, view.text.utf16.count), length: 0)
            if isScrollEnabled {
                view.setContentOffset(offset, animated: false)
            }
            context.coordinator.appliedFontSize = fontSize
        }
        view.typingAttributes = attributes
        if !isScrollEnabled {
            context.coordinator.updateLayout(in: view)
        }
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
#if DEBUG
        private static let logger = Logger(subsystem: "com.dobby.Dobby", category: "ProductInputScroll")
#endif
        var parent: DescriptionTextView
        var appliedFontSize: CGFloat?
        weak var textView: UITextView?
        private var keyboardFrame = CGRect.null

        init(_ parent: DescriptionTextView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardFrameDidChange),
                name: UIResponder.keyboardDidChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardFrameDidChange),
                name: UIResponder.keyboardDidShowNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if !parent.isScrollEnabled {
                updateLayout(in: textView, reason: "text-change")
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = parent.textAttributes
            if !parent.isScrollEnabled {
                updateLayout(in: textView, reason: "selection-change")
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isScrollEnabled {
                updateLayout(in: textView, reason: "begin-editing")
            }
        }

        func updateLayout(in textView: UITextView, reason: String = "layout-update") {
            Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView, let selection = textView.selectedTextRange else { return }
                textView.layoutIfNeeded()
                let width = textView.bounds.width
                var heightChanged = false
                if width > 0, let contentHeight = parent.contentHeight {
                    let fittingHeight = ceil(textView.sizeThatFits(
                        CGSize(width: width, height: .greatestFiniteMagnitude)
                    ).height)
                    let height = max(172, fittingHeight)
                    if abs(contentHeight.wrappedValue - height) > 0.5 {
                        contentHeight.wrappedValue = height
                        heightChanged = true
                    }
                }
                if heightChanged {
                    await Task.yield()
                    textView.window?.layoutIfNeeded()
                }
                revealCaret(selection.end, in: textView, reason: reason)
            }
        }

        @objc private func keyboardFrameDidChange(_ notification: Notification) {
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            keyboardFrame = frame
            guard let textView, textView.isFirstResponder, !parent.isScrollEnabled else { return }
            updateLayout(in: textView, reason: "keyboard-change")
        }

        @MainActor
        private func revealCaret(_ position: UITextPosition, in textView: UITextView, reason: String) {
            guard textView.isFirstResponder,
                  let scrollView = enclosingScrollView(of: textView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return }

            let caretFrame = textView.caretRect(for: position)
            var targetFrame = textView.convert(caretFrame, to: scrollView).insetBy(dx: 0, dy: -12)
            let keyboardOverlap = uncoveredKeyboardOverlapHeight(scrollView: scrollView)
            targetFrame.size.height += keyboardOverlap
            let beforeOffsetY = scrollView.contentOffset.y

#if DEBUG
            Self.logger.debug("request reason=\(reason, privacy: .public) offsetY=\(Double(beforeOffsetY)) caretY=\(Double(targetFrame.minY)) targetMaxY=\(Double(targetFrame.maxY)) viewportHeight=\(Double(scrollView.bounds.height)) contentHeight=\(Double(scrollView.contentSize.height)) insetBottom=\(Double(scrollView.adjustedContentInset.bottom)) keyboardOverlap=\(Double(keyboardOverlap))")
#endif

            scrollView.scrollRectToVisible(targetFrame, animated: false)

#if DEBUG
            let afterOffsetY = scrollView.contentOffset.y
            Self.logger.debug("result reason=\(reason, privacy: .public) offsetY=\(Double(beforeOffsetY)) -> \(Double(afterOffsetY))")
#endif
        }

        private func enclosingScrollView(of textView: UITextView) -> UIScrollView? {
            var ancestor = textView.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                ancestor = view.superview
            }
#if DEBUG
            Self.logger.error("Unable to find the product information scroll view.")
#endif
            return nil
        }

        private func uncoveredKeyboardOverlapHeight(scrollView: UIScrollView) -> CGFloat {
            guard !keyboardFrame.isNull, let window = scrollView.window else { return 0 }
            let keyboardFrameInWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let scrollFrameInWindow = scrollView.convert(scrollView.bounds, to: window)
            let overlap = scrollFrameInWindow.intersection(keyboardFrameInWindow).height
            return max(0, overlap - scrollView.adjustedContentInset.bottom)
        }
    }
}

struct ProductPriceField: View {
    @Bindable var garment: Garment
    let focus: FocusState<ProductInformationField?>.Binding
    var usesEditingLayout = false
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProductFieldTitle(title: "가격", isRequired: true)
                .frame(minHeight: usesEditingLayout ? 22 : nil, alignment: .leading)
            ProductPriceInput(price: $garment.price, focus: focus)
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
        .id(ProductInformationField.price)
    }
}

private struct ProductPriceInput: View {
    @Binding var price: Int?
    let focus: FocusState<ProductInformationField?>.Binding
    @State private var priceText = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(priceText.isEmpty ? "제품 가격" : priceText)
                .font(.custom(priceText.isEmpty ? "Pretendard-Regular" : "Pretendard-SemiBold",
                              size: priceText.isEmpty ? 17 : 15,
                              relativeTo: priceText.isEmpty ? .body : .subheadline))
                .hidden()
                .padding(.trailing, 2)
                .overlay {
                    TextField("", text: $priceText, prompt: Text("제품 가격")
                        .font(.custom("Pretendard-Regular", size: 17, relativeTo: .body))
                        .foregroundStyle(Color("BrandNeutral300")))
                        .font(.custom("Pretendard-SemiBold", size: 15, relativeTo: .subheadline))
                        .keyboardType(.numberPad)
                        .focused(focus, equals: .price)
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
        .onTapGesture { focus.wrappedValue = .price }
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
