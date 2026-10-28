import SwiftUI
import UIKit

struct ProductInformationDiscardConfirmation: View {
    let onCancel: () -> Void
    let onDiscard: () -> Void

    @ScaledMetric(relativeTo: .title3) private var titleFontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var titleLineHeight: CGFloat = 29
    @ScaledMetric(relativeTo: .callout) private var messageFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var buttonFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var buttonLineHeight: CGFloat = 20
    @AccessibilityFocusState private var titleIsFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)

            confirmationPanel
                .padding(.horizontal, 16)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("product-info.discard-confirmation")
        .accessibilityAction(.escape, onCancel)
        .onAppear { titleIsFocused = true }
    }

    private var confirmationPanel: some View {
        VStack(spacing: 16) {
            confirmationMessage
                .padding(.vertical, 12)
            confirmationActions
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 358)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
    }

    private var confirmationMessage: some View {
        VStack(spacing: 8) {
            styledText("저장하지 않은 변경사항이 있어요", fontName: "Pretendard-Bold",
                       size: titleFontSize, lineHeight: titleLineHeight)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleIsFocused)
            styledText("변경사항을 삭제하고 보관함으로 나갈까요?", fontName: "Pretendard-Regular",
                       size: messageFontSize, lineHeight: messageLineHeight)
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
    }

    private var confirmationActions: some View {
        HStack(spacing: 12) {
            Button(role: .cancel, action: onCancel) {
                actionLabel("닫기")
                    .foregroundStyle(Color("BrandNeutral900"))
            }
            .accessibilityIdentifier("product-info.discard-cancel")

            Button(role: .destructive, action: onDiscard) {
                actionLabel("삭제하고 나가기")
                    .foregroundStyle(Color("AccentsRed"))
            }
            .accessibilityIdentifier("product-info.discard-exit")
        }
        .buttonStyle(.plain)
        .frame(height: 54, alignment: .topLeading)
    }

    private func actionLabel(_ title: String) -> some View {
        styledText(title, fontName: "Pretendard-Medium",
                   size: buttonFontSize, lineHeight: buttonLineHeight)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("BrandNeutral100"), in: RoundedRectangle(cornerRadius: 60))
            .contentShape(RoundedRectangle(cornerRadius: 60))
    }

    private func styledText(_ value: String, fontName: String, size: CGFloat,
                            lineHeight: CGFloat) -> some View {
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
#Preview("제품 정보 변경 취소") {
    ProductInformationDiscardConfirmation(onCancel: { }, onDiscard: { })
}
#endif
