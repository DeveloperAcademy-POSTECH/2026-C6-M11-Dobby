import SwiftUI
import UIKit

struct ProductInformationDiscardConfirmation: View {
    let onCancel: () -> Void
    let onDiscard: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleFontSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var messageFontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var messageLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) private var buttonFontSize: CGFloat = 17
    @ScaledMetric(relativeTo: .headline) private var buttonLineHeight: CGFloat = 22

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
    }

    private var confirmationPanel: some View {
        VStack(spacing: 16) {
            confirmationMessage
                .padding(.vertical, 12)
            confirmationActions
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .frame(maxWidth: 358)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 44))
        .environment(\.colorScheme, .light)
    }

    private var confirmationMessage: some View {
        VStack(spacing: 8) {
            styledText("저장하지 않은 변경사항이 있어요", fontName: "Pretendard-Bold",
                       size: titleFontSize, lineHeight: titleLineHeight, tracking: -0.26 * titleFontSize / 22)
                .accessibilityModalHeading()
            styledText("변경사항을 삭제하고 보관함으로 나갈까요?", fontName: "Pretendard-Regular",
                       size: messageFontSize, lineHeight: messageLineHeight, tracking: -0.43 * messageFontSize / 17)
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
    }

    private var confirmationActions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button(role: .cancel, action: onCancel) {
                actionLabel("닫기", background: "BrandMain50")
                    .foregroundStyle(Color("BrandMain600"))
            }
            .accessibilityIdentifier("product-info.discard-cancel")
            .accessibilityHint("변경한 내용을 유지하고 수정 화면으로 돌아갑니다")

            Button(role: .destructive, action: onDiscard) {
                actionLabel("삭제하고 나가기")
                    .foregroundStyle(Color("AccentsRed"))
            }
            .accessibilityIdentifier("product-info.discard-exit")
            .accessibilityHint("저장하지 않은 변경사항을 버리고 보관함으로 돌아갑니다")
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, background: String = "BrandNeutral100") -> some View {
        styledText(title, fontName: "Pretendard-SemiBold",
                   size: buttonFontSize,
                   lineHeight: buttonLineHeight,
                   tracking: -0.43 * buttonFontSize / 17)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color(background), in: RoundedRectangle(cornerRadius: 60))
            .contentShape(RoundedRectangle(cornerRadius: 60))
    }

    private func styledText(_ value: String, fontName: String, size: CGFloat,
                            lineHeight: CGFloat, tracking: CGFloat) -> some View {
        let font = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
        let lineHeightAdjustment = max(0, lineHeight - font.lineHeight)

        return Text(value)
            .font(.custom(fontName, fixedSize: size))
            .tracking(tracking)
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
