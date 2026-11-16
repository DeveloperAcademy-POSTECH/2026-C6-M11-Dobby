import SwiftUI
import UIKit

/// The flow hosts this above its NavigationStack so the dimmer also covers toolbars.
struct ProductAutofillLoadingPresentation {
    let onCancel: () -> Void
}

struct ProductAutofillLoadingView: View {
    let onCancel: () -> Void
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var messageLineHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = min(312, max(0, geometry.size.width - 40))
            let imageSide = max(0, width - 32)
            ZStack {
                Color.black.opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)

                ViewThatFits(in: .vertical) {
                    card(width: width, imageSide: imageSide)
                    ScrollView { card(width: width, imageSide: imageSide) }
                        .scrollIndicators(.hidden)
                }
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("product-ai.loading")
            .accessibilityAction(.escape, onCancel)
        }
        .ignoresSafeArea()
    }

    private func card(width: CGFloat, imageSide: CGFloat) -> some View {
        VStack(spacing: 8) {
            Text("AI가 정보 생성 중...")
                .font(.custom("Pretendard-Bold", fixedSize: titleSize))
                .tracking(-0.26)
                .frame(minHeight: titleLineHeight)
                .accessibilityModalHeading()
                .accessibilityHint("동작 메뉴에서 정보 생성을 취소할 수 있습니다.")
                .accessibilityAction(named: Text("정보 생성 취소"), onCancel)

            UploadLoadingAnimation(source: .upload, width: imageSide, height: imageSide)
                .accessibilityHidden(true)

            Text("사진을 꼼꼼히 보며\n어떤 옷인지 알아보고 있어요")
                .font(.custom("Pretendard-Regular", fixedSize: messageSize))
                .tracking(-0.43)
                .lineSpacing(max(0, messageLineHeight - (UIFont(name: "Pretendard-Regular", size: messageSize)?.lineHeight ?? messageSize)))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: messageLineHeight * 2)
        }
        .foregroundStyle(Color("BrandNeutralBlack"))
        .padding(.vertical, 12)
        .padding(16)
        .frame(width: width)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 44, style: .circular))
        .clipShape(RoundedRectangle(cornerRadius: 44, style: .circular))
        .shadow(color: .black.opacity(0.25), radius: 4)
    }
}
