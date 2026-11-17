import SwiftUI
import UIKit

private nonisolated enum Cafe24InputField: Hashable {
    case productName, productDescription, price
}

struct Cafe24ProductView: View {
    @Binding var draft: Cafe24ExportDraft
    @FocusState private var focusedField: Cafe24InputField?
    let mallID: String
    let isDisabled: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ExportUploadAccountCard(accountLabel: "@\(mallID).cafe24.com") {
                        EmptyView()
                    }
                    .onTapGesture(perform: dismissKeyboard)
                    Cafe24ProductPhotos(photos: draft.photos)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissKeyboard)
                    Cafe24ProductNameField(text: $draft.productName, focus: $focusedField) {
                        dismissKeyboard()
                        draft.resetProductName()
                    }
                    .disabled(isDisabled)
                    .id(Cafe24InputField.productName)
                    Cafe24ProductDescriptionField(text: $draft.productDescription, focus: $focusedField) {
                        dismissKeyboard()
                        draft.resetProductDescription()
                    }
                    .disabled(isDisabled)
                    Cafe24PriceField(priceText: $draft.priceText, focus: $focusedField) {
                        dismissKeyboard()
                        draft.resetPrice()
                    }
                    .disabled(isDisabled)
                    .id(Cafe24InputField.price)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 43)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismissKeyboard)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background {
                Color(.brandNeutralWhite)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissKeyboard)
                    .ignoresSafeArea()
            }
            .onChange(of: focusedField) {
                revealFocusedField(using: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification
            )) { _ in
                revealFocusedField(using: proxy)
            }
            .onChange(of: isDisabled) {
                if isDisabled { dismissKeyboard() }
            }
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func revealFocusedField(using proxy: ScrollViewProxy) {
        guard let focusedField, focusedField != .productDescription else { return }

        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(focusedField, anchor: .center)
            }
        }
    }
}

private struct Cafe24GrowingDescriptionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        guard textView.markedTextRange == nil else { return }

        if textView.text != text {
            let selection = textView.selectedRange
            textView.attributedText = NSAttributedString(string: text, attributes: textAttributes)
            textView.selectedRange = NSRange(
                location: min(selection.location, textView.text.utf16.count),
                length: 0
            )
        }
        textView.typingAttributes = textAttributes
        context.coordinator.updateLayout(in: textView)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont(name: "Pretendard-Regular", size: 17) ?? UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor(named: "BrandNeutralBlack") ?? UIColor.label
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: Cafe24GrowingDescriptionTextView
        weak var textView: UITextView?
        private var keyboardFrame = CGRect.null

        init(_ parent: Cafe24GrowingDescriptionTextView) {
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
            guard textView.markedTextRange == nil else { return }
            parent.text = textView.text
            updateLayout(in: textView)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard textView.markedTextRange == nil else { return true }
            guard let textRange = Range(range, in: textView.text) else { return false }
            let newText = textView.text.replacingCharacters(in: textRange, with: replacement)
            return ProductTextLimit.allowsChange(
                from: textView.text,
                to: newText,
                maximumLength: ProductTextLimit.detail
            )
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = parent.textAttributes
            updateLayout(in: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            updateLayout(in: textView)
        }

        func updateLayout(in textView: UITextView) {
            Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard let self, let textView, let selection = textView.selectedTextRange else { return }

                textView.layoutIfNeeded()
                let width = textView.bounds.width
                var heightChanged = false
                if width > 0 {
                    let fittingHeight = ceil(textView.sizeThatFits(
                        CGSize(width: width, height: .greatestFiniteMagnitude)
                    ).height)
                    let height = max(22, fittingHeight)
                    if abs(parent.contentHeight - height) > 0.5 {
                        parent.contentHeight = height
                        heightChanged = true
                    }
                }
                if heightChanged {
                    await Task.yield()
                    textView.window?.layoutIfNeeded()
                }
                revealCaret(selection.end, in: textView)
            }
        }

        @objc private func keyboardFrameDidChange(_ notification: Notification) {
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            keyboardFrame = frame
            guard let textView, textView.isFirstResponder else { return }
            updateLayout(in: textView)
        }

        @MainActor
        private func revealCaret(_ position: UITextPosition, in textView: UITextView) {
            guard textView.isFirstResponder,
                  let scrollView = enclosingScrollView(of: textView),
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating else { return }

            let caretFrame = textView.caretRect(for: position)
            var targetFrame = textView.convert(caretFrame, to: scrollView).insetBy(dx: 0, dy: -12)
            targetFrame.size.height += uncoveredKeyboardOverlapHeight(scrollView: scrollView)
            scrollView.scrollRectToVisible(targetFrame, animated: false)
        }

        private func enclosingScrollView(of textView: UITextView) -> UIScrollView? {
            var ancestor = textView.superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                ancestor = view.superview
            }
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

private struct Cafe24ProductPhotos: View {
    let photos: [Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("업로드할 사진")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Cafe24PhotoStrip(photos: photos)
        }
    }
}

private struct Cafe24PhotoStrip: View {
    let photos: [Data]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                if photos.isEmpty {
                    Cafe24ProductPhoto(data: nil)
                        .accessibilityLabel("업로드할 상품 사진 없음")
                } else {
                    ForEach(photos.indices, id: \.self) { index in
                        Cafe24ProductPhoto(data: photos[index])
                            .accessibilityLabel("업로드할 상품 사진 \(index + 1)")
                            .accessibilityValue("전체 \(photos.count)장")
                    }
                }
            }
        }
    }
}

private struct Cafe24ProductPhoto: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "tshirt")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 212)
        .background(Color(.brandNeutral100))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
    }
}

private struct Cafe24ProductNameField: View {
    @Binding var text: String
    let focus: FocusState<Cafe24InputField?>.Binding
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "상품명", onReset: onReset)
            TextField("상품명 입력", text: limitedText)
                .focused(focus, equals: .productName)
                .font(.body)
                .foregroundStyle(Color(.brandNeutralBlack))
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("카페24 상품명")
        }
    }

    private var limitedText: Binding<String> {
        Binding {
            text
        } set: { newText in
            guard ProductTextLimit.allowsChange(
                from: text,
                to: newText,
                maximumLength: ProductTextLimit.name
            ) else { return }
            text = newText
        }
    }
}

private struct Cafe24ProductDescriptionField: View {
    @Binding var text: String
    let focus: FocusState<Cafe24InputField?>.Binding
    let onReset: () -> Void
    @State private var contentHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "상품 설명", onReset: onReset)
            Cafe24GrowingDescriptionTextView(text: $text, contentHeight: $contentHeight)
                .focused(focus, equals: .productDescription)
                .frame(height: contentHeight, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("상품 설명")
                            .font(.custom("Pretendard-Regular", fixedSize: 17))
                            .foregroundStyle(Color(.brandNeutral300))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("카페24 상품 설명")
        }
    }
}

private struct Cafe24PriceField: View {
    @Binding var priceText: String
    let focus: FocusState<Cafe24InputField?>.Binding
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "판매가", onReset: onReset)
            Cafe24PriceInput(priceText: $priceText, focus: focus)
        }
    }
}

private struct Cafe24PriceInput: View {
    @Binding var priceText: String
    let focus: FocusState<Cafe24InputField?>.Binding

    var body: some View {
        HStack(alignment: .center) {
            TextField("판매가 입력", text: formattedPrice)
                .focused(focus, equals: .price)
                .keyboardType(.numberPad)
                .font(.custom("Pretendard-SemiBold", size: 17, relativeTo: .headline))
                .foregroundStyle(Color(.brandNeutralBlack))
                .accessibilityLabel("카페24 판매가, 원")
            Spacer()
            Text("원")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 14))
    }

    private var formattedPrice: Binding<String> {
        Binding {
            guard let price = Int(priceText.filter(\.isNumber)) else { return priceText }
            return price.formatted(.number.locale(Locale(identifier: "ko_KR")))
        } set: { text in
            priceText = String(text.filter(\.isNumber))
        }
    }
}

private struct Cafe24EditorHeader: View {
    let title: String
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Cafe24EditorTitle(title: title)
            Spacer()
            Cafe24ResetButton(action: onReset)
                .accessibilityLabel("\(title) 초기화")
                .accessibilityHint("수정한 \(title)을 원래 상품 정보로 되돌립니다.")
        }
    }
}

private struct Cafe24EditorTitle: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
                .accessibilityAddTraits(.isHeader)
            Text("눌러서 직접 글을 수정할 수 있어요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Cafe24ResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("초기화", systemImage: "arrow.clockwise")
                .font(.subheadline)
                .foregroundStyle(Color(.brandNeutral800))
        }
        .buttonStyle(.plain)
    }
}

#Preview("상품 편집") {
    @Previewable @State var draft = Cafe24ExportDraft(product: .demo)

    Cafe24ProductView(
        draft: $draft,
        mallID: "myshop",
        isDisabled: false
    )
}

#Preview("업로드할 사진", traits: .sizeThatFitsLayout) {
    let draft = Cafe24ExportDraft(product: .demo)

    Cafe24ProductPhotos(photos: draft.photos)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("사진 목록", traits: .sizeThatFitsLayout) {
    let draft = Cafe24ExportDraft(product: .demo)

    Cafe24PhotoStrip(photos: draft.photos)
        .frame(width: 363, height: 212)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("상품 사진", traits: .sizeThatFitsLayout) {
    let draft = Cafe24ExportDraft(product: .demo)

    Cafe24ProductPhoto(data: draft.photos.first)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("상품명 입력", traits: .sizeThatFitsLayout) {
    @Previewable @State var text = "빈티지 재킷"
    @Previewable @FocusState var focusedField: Cafe24InputField?

    Cafe24ProductNameField(text: $text, focus: $focusedField, onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("상품 설명 입력", traits: .sizeThatFitsLayout) {
    @Previewable @State var text = "가볍게 걸치기 좋은 빈티지 재킷입니다."
    @Previewable @FocusState var focusedField: Cafe24InputField?

    Cafe24ProductDescriptionField(text: $text, focus: $focusedField, onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("판매가 입력", traits: .sizeThatFitsLayout) {
    @Previewable @State var priceText = "89,000"
    @Previewable @FocusState var focusedField: Cafe24InputField?

    Cafe24PriceField(priceText: $priceText, focus: $focusedField, onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("편집 제목", traits: .sizeThatFitsLayout) {
    Cafe24EditorHeader(title: "상품명", onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("편집 안내", traits: .sizeThatFitsLayout) {
    Cafe24EditorTitle(title: "상품명")
        .padding()
        .background(Color(.brandNeutral50))
}

#Preview("초기화 버튼", traits: .sizeThatFitsLayout) {
    Cafe24ResetButton(action: {})
        .padding()
        .background(Color(.brandNeutral50))
}
