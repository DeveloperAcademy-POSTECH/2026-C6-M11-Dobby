import SwiftUI
import UIKit

/// Acknowledges a failed capture without replacing the live camera behind it.
struct MeasurementCaptureFailureOverlay: View {
    let onConfirm: () -> Void

    @ScaledMetric(relativeTo: .title3) private var titleFontSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var titleLineHeight: CGFloat = 29
    @ScaledMetric(relativeTo: .callout) private var messageFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var buttonFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var buttonLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .callout) private var buttonHeight: CGFloat = 54
    @AccessibilityFocusState private var titleIsFocused: Bool

    var body: some View {
        ZStack {
            // The reference has no dimming scrim. Consume outside touches so
            // they cannot focus the camera, fire the shutter, or dismiss this.
            Color.clear
                .contentShape(Rectangle())
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
        .accessibilityIdentifier("garmentCaptureFailureOverlay")
        .accessibilityAction(.escape, onConfirm)
        .onAppear { titleIsFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                styledText("실측 실패", fontName: "Pretendard-Bold",
                           size: titleFontSize, lineHeight: titleLineHeight)
                    .foregroundStyle(Color("AccentsRed"))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleIsFocused)
                    .accessibilityIdentifier("garmentCaptureFailureTitle")

                styledText("실측에 실패했어요\n다시 촬영해주세요", fontName: "Pretendard-Regular",
                           size: messageFontSize, lineHeight: messageLineHeight)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("garmentCaptureFailureMessage")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Button(action: onConfirm) {
                styledText("확인", fontName: "Pretendard-Medium",
                           size: buttonFontSize, lineHeight: buttonLineHeight)
                    .foregroundStyle(Color("BrandNeutralWhite"))
                    .frame(maxWidth: .infinity, minHeight: buttonHeight)
                    .contentShape(Capsule())
                    .background(Color("BrandMain500"), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 326)
            .accessibilityIdentifier("confirmGarmentCaptureFailure")
        }
        .padding(16)
        .frame(maxWidth: 360)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
    }

    private func styledText(_ value: String, fontName: String, size: CGFloat,
                            lineHeight: CGFloat) -> some View {
        let font = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
        let adjustment = max(0, lineHeight - font.lineHeight)

        return Text(value)
            .font(.custom(fontName, fixedSize: size))
            .tracking(-size * 0.01)
            .lineSpacing(adjustment)
            .padding(.vertical, adjustment / 2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("실측 실패") {
    Color.gray
        .ignoresSafeArea()
        .overlay { MeasurementCaptureFailureOverlay(onConfirm: { }) }
}

#Preview("실측 실패 · 큰 글자") {
    MeasurementCaptureFailureOverlay(onConfirm: { })
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
