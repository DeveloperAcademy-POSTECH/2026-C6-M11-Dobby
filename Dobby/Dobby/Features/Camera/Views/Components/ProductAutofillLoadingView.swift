import SwiftUI
import UIKit

/// The flow hosts this above its NavigationStack so the dimmer also covers toolbars.
struct ProductAutofillLoadingPresentation {
    let onCancel: () -> Void
}

struct ProductAutofillLoadingView: View {
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var titleLineHeight: CGFloat = 29
    @ScaledMetric(relativeTo: .callout) private var messageSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let width = min(360, max(0, geometry.size.width - 32))
            ZStack {
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("AI가 정보 생성 중...")
                        .font(.custom("Pretendard-Bold", fixedSize: titleSize))
                        .tracking(-0.2)
                        .frame(minHeight: titleLineHeight)
                        .padding(.horizontal, 16)

                    UploadLoadingAnimation(source: .aiInformation, width: width, height: 123)

                    Text("사진을 꼼꼼히 보며\n어떤 옷인지 알아보고 있어요")
                        .font(.custom("Pretendard-Regular", fixedSize: messageSize))
                        .tracking(-0.16)
                        .lineSpacing(max(0, messageLineHeight - (UIFont(name: "Pretendard-Regular", size: messageSize)?.lineHeight ?? messageSize)))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: messageLineHeight * 2)
                        .padding(.horizontal, 16)
                }
                .foregroundStyle(Color("BrandNeutralBlack"))
                .padding(.vertical, 28)
                .frame(width: width)
                .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottom) {
                    // Keep cancellation outside the design's loading card.
                    Button("취소", action: onCancel)
                        .font(.custom("Pretendard-Medium", size: 16, relativeTo: .callout))
                        .foregroundStyle(.white)
                        .frame(minWidth: 80, minHeight: 44)
                        .contentShape(Rectangle())
                        .offset(y: 52)
                        .accessibilityIdentifier("product-ai.cancel")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("product-ai.loading")
            .accessibilityAction(.escape, onCancel)
        }
        .ignoresSafeArea()
    }
}
