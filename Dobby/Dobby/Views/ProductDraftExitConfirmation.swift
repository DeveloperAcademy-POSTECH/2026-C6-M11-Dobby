import SwiftUI
import UIKit

struct ProductDraftExitConfirmation: View {
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var messageFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var buttonFontSize: CGFloat = 16
    @AccessibilityFocusState private var messageIsFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                // Outside taps are consumed without dismissing the confirmation.
                .onTapGesture { }
                .accessibilityHidden(true)

            ViewThatFits(in: .vertical) {
                panel
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    panel
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("product-flow.exit-confirmation")
        .accessibilityAction(.escape, onCancel)
        .onAppear { messageIsFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            message
                .padding(.vertical, 12)

            if dynamicTypeSize.isAccessibilitySize {
                stackedActions
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        cancelButton(wraps: false)
                            .frame(width: 110)
                        saveButton(wraps: false)
                    }

                    stackedActions
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
    }

    private var message: some View {
        let font = UIFont(name: "Pretendard-Regular", size: messageFontSize)
            ?? UIFont.systemFont(ofSize: messageFontSize)
        let lineHeightAdjustment = messageLineHeight - font.lineHeight

        return Text("메인화면으로 나갈까요?\n작성된 내용은 자동으로 임시저장되고\n사라지지 않아요.")
            .font(.custom("Pretendard-Regular", fixedSize: messageFontSize))
            .tracking(-messageFontSize * 0.01)
            .lineSpacing(lineHeightAdjustment)
            .padding(.vertical, lineHeightAdjustment / 2)
            .foregroundStyle(.black)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("product-flow.exit-message")
            .accessibilityFocused($messageIsFocused)
    }

    private var stackedActions: some View {
        VStack(spacing: 12) {
            cancelButton(wraps: true)
            saveButton(wraps: true)
        }
    }

    private func cancelButton(wraps: Bool) -> some View {
        Button(role: .cancel, action: onCancel) {
            actionLabel("취소", wraps: wraps)
                .foregroundStyle(Color(red: 32.0 / 255, green: 30.0 / 255, blue: 27.0 / 255))
                .background(Color(red: 226.0 / 255, green: 225.0 / 255, blue: 223.0 / 255), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("product-flow.exit-cancel")
    }

    private func saveButton(wraps: Bool) -> some View {
        Button(action: onSave) {
            actionLabel("임시저장하고 나가기", wraps: wraps)
                .foregroundStyle(.white)
                .background(LibraryStyle.editAccent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("product-flow.exit-save")
    }

    private func actionLabel(_ title: String, wraps: Bool) -> some View {
        Text(title)
            .font(.system(size: buttonFontSize, weight: .semibold).italic())
            .tracking(-buttonFontSize * 0.31 / 16)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !wraps, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Capsule())
    }
}

#if DEBUG
#Preview("임시저장 후 나가기") {
    Color.black
        .overlay {
            ProductDraftExitConfirmation(onCancel: { }, onSave: { })
        }
}

#Preview("임시저장 후 나가기 · 큰 글자") {
    ProductDraftExitConfirmation(onCancel: { }, onSave: { })
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
