import SwiftUI
import UIKit

struct ProductDraftExitConfirmation: View {
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    @ScaledMetric(relativeTo: .title3) private var titleFontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var titleLineHeight: CGFloat = 29
    @ScaledMetric(relativeTo: .callout) private var messageFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var buttonFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var buttonLineHeight: CGFloat = 20
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

            VStack(spacing: 12) {
                Button(action: onSave) {
                    actionLabel("임시저장하고 나가기")
                        .foregroundStyle(.white)
                        .background(LibraryStyle.editAccent, in: Capsule())
                }
                .accessibilityIdentifier("product-flow.exit-save")

                Button(role: .destructive, action: onDiscard) {
                    actionLabel("삭제하고 나가기")
                        .foregroundStyle(Color("AccentsRed"))
                        .background(Color("DraftExitSecondaryBackground"), in: Capsule())
                }
                .accessibilityIdentifier("product-flow.exit-discard")

                Button(role: .cancel, action: onCancel) {
                    actionLabel("닫기")
                        .foregroundStyle(Color("BrandNeutral900"))
                        .background(Color("DraftExitSecondaryBackground"), in: Capsule())
                }
                .accessibilityIdentifier("product-flow.exit-cancel")
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: 358)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
    }

    private var message: some View {
        VStack(spacing: 8) {
            styledText("작성 중인 상품이 있어요", fontName: "Pretendard-Bold",
                       size: titleFontSize, lineHeight: titleLineHeight)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("product-flow.exit-title")
                .accessibilityFocused($messageIsFocused)
            styledText("나중에 이어서 작성할 수 있도록 임시 저장할까요?", fontName: "Pretendard-Regular",
                       size: messageFontSize, lineHeight: messageLineHeight)
                .accessibilityIdentifier("product-flow.exit-message")
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
    }

    private func actionLabel(_ title: String) -> some View {
        styledText(title, fontName: "Pretendard-Medium", size: buttonFontSize, lineHeight: buttonLineHeight)
            .padding(.horizontal, 28)
            .padding(.vertical, 17)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Capsule())
    }

    private func styledText(_ value: String, fontName: String, size: CGFloat, lineHeight: CGFloat) -> some View {
        let font = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
        let lineHeightAdjustment = max(0, lineHeight - font.lineHeight)

        return Text(value)
            .font(.custom(fontName, fixedSize: size))
            .tracking(-size * 0.01)
            .lineSpacing(lineHeightAdjustment)
            .padding(.vertical, lineHeightAdjustment / 2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("임시저장 후 나가기") {
    Color.black
        .overlay {
            ProductDraftExitConfirmation(onCancel: { }, onSave: { }, onDiscard: { })
        }
}

#Preview("임시저장 후 나가기 · 큰 글자") {
    ProductDraftExitConfirmation(onCancel: { }, onSave: { }, onDiscard: { })
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
