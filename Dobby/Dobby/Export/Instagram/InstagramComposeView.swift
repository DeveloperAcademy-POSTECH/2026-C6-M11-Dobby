import SwiftUI
import UIKit

struct InstagramComposeView: View {
    let account: InstagramAccount
    @Binding var draft: InstagramExportDraft
    let isDisabled: Bool
    let onDismissKeyboard: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 24) {
                InstagramAccountCard(account: account)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismissKeyboard)
                InstagramPhotoEditor(photos: draft.photos)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismissKeyboard)
                    .disabled(isDisabled)
                InstagramCaptionEditor(draft: $draft, onDismissKeyboard: onDismissKeyboard)
                    .disabled(isDisabled)
                    .frame(maxWidth: 363)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismissKeyboard)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background {
            Color(.brandNeutralWhite)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismissKeyboard)
                .ignoresSafeArea()
        }
    }
}

private struct InstagramAccountCard: View {
    let account: InstagramAccount

    var body: some View {
        ExportUploadAccountCard(accountLabel: "@\(account.username)") {
            InstagramProfileImage(url: account.profilePictureURL)
        }
    }
}

private struct InstagramPhotoEditor: View {
    let photos: [InstagramDraftPhoto]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("업로드할 사진")
                .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                .foregroundStyle(Color(.brandNeutral950))
                .frame(maxWidth: 363, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            GeometryReader { geometry in
                let horizontalInset = max(0, (geometry.size.width - 363) / 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(photos) { photo in
                            InstagramDraftPhotoCell(photo: photo)
                        }
                    }
                }
                .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
            }
            .frame(height: 212)
        }
    }
}

private struct InstagramDraftPhotoCell: View {
    let photo: InstagramDraftPhoto

    var body: some View {
        Group {
            if let image = UIImage(data: photo.data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 212)
        .background(Color(.brandNeutral100))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct InstagramCaptionEditor: View {
    @Binding var draft: InstagramExportDraft
    let onDismissKeyboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InstagramCaptionHeader(onDismissKeyboard: onDismissKeyboard) {
                onDismissKeyboard()
                draft.resetCaption()
            }
            InstagramCaptionInput(text: $draft.caption)

            if let validationMessage = draft.validationMessage,
               draft.photos.isEmpty == false {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .onTapGesture(perform: onDismissKeyboard)
            }
        }
    }
}

private struct InstagramCaptionHeader: View {
    let onDismissKeyboard: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("캡션")
                    .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                    .foregroundStyle(Color(.brandNeutral950))
                Text("눌러서 직접 글을 수정할 수 있어요")
                    .font(.custom("Pretendard-Regular", fixedSize: 14))
                    .foregroundStyle(Color(.brandNeutral700))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismissKeyboard)
            Spacer()
            InstagramResetButton(action: onReset)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct InstagramCaptionInput: View {
    @Binding var text: String
    @State private var contentHeight: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            InstagramGrowingCaptionTextView(text: $text, contentHeight: $contentHeight)
                .frame(height: contentHeight, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.brandNeutral50))
                // Keep taps on the editor padding from reaching the dismissal background.
                .onTapGesture { }
        }
    }
}

/// Expands with the caption and keeps the active caret above the keyboard.
private struct InstagramGrowingCaptionTextView: UIViewRepresentable {
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
            .foregroundColor: UIColor.label
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InstagramGrowingCaptionTextView
        weak var textView: UITextView?
        private var keyboardFrame = CGRect.null
        private var layoutTask: Task<Void, Never>?

        init(_ parent: InstagramGrowingCaptionTextView) {
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
            updateLayout(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = parent.textAttributes
            updateLayout(in: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            updateLayout(in: textView)
        }

        func updateLayout(in textView: UITextView) {
            layoutTask?.cancel()
            layoutTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let textView else { return }

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
                }
                await revealCaret(in: textView)
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
        private func revealCaret(in textView: UITextView) async {
            guard let scrollView = enclosingScrollView(of: textView) else { return }

            // UIKit may report the new selection before the scroll view releases the tap.
            for _ in 0..<8 {
                guard !Task.isCancelled, textView.isFirstResponder,
                      !scrollView.isDragging, !scrollView.isDecelerating else { return }
                guard scrollView.isTracking else { break }
                try? await Task.sleep(for: .milliseconds(20))
            }

            guard !Task.isCancelled, textView.isFirstResponder,
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating,
                  let window = textView.window else { return }

            window.layoutIfNeeded()
            guard !Task.isCancelled, let position = textView.selectedTextRange?.end else { return }
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

private struct InstagramResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                Text("초기화")
                    .font(.custom("Pretendard-Regular", fixedSize: 14))
            }
                .foregroundStyle(Color(.brandNeutral800))
        }
        .buttonStyle(.plain)
    }
}

struct InstagramProfileImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(ExportScreenStyle.accent)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityHidden(true)
    }
}

#Preview("사진 3장 · 캡션 편집") {
    @Previewable @State var draft = InstagramExportDraft(product: .instagramPreview)

    InstagramComposeView(
        account: .preview,
        draft: $draft,
        isDisabled: false,
        onDismissKeyboard: {}
    )
}

#Preview("계정 카드", traits: .sizeThatFitsLayout) {
    InstagramAccountCard(account: .preview)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("프로필 이미지", traits: .sizeThatFitsLayout) {
    InstagramProfileImage(url: nil)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("업로드할 사진", traits: .sizeThatFitsLayout) {
    let draft = InstagramExportDraft(product: .instagramPreview)

    InstagramPhotoEditor(photos: draft.photos)
        .frame(width: 402, height: 246)
        .background(Color(.brandNeutralWhite))
}

#Preview("사진 셀", traits: .sizeThatFitsLayout) {
    let draft = InstagramExportDraft(product: .instagramPreview)

    if let photo = draft.photos.first {
        InstagramDraftPhotoCell(photo: photo)
            .padding()
            .background(Color(.brandNeutralWhite))
    }
}

#Preview("캡션 편집", traits: .sizeThatFitsLayout) {
    @Previewable @State var draft = InstagramExportDraft(product: .instagramPreview)

    InstagramCaptionEditor(draft: $draft, onDismissKeyboard: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("캡션 제목", traits: .sizeThatFitsLayout) {
    InstagramCaptionHeader(onDismissKeyboard: {}, onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("캡션 입력란", traits: .sizeThatFitsLayout) {
    @Previewable @State var text = "90s 나이키 자켓\n\n가격: 89,000원"

    InstagramCaptionInput(text: $text)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("초기화 버튼", traits: .sizeThatFitsLayout) {
    InstagramResetButton(action: {})
        .padding()
        .background(Color(.brandNeutralWhite))
}
