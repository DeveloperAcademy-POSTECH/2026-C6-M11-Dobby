import SwiftUI
import UIKit

struct PlatformUploadingOverlay: View {
    let platformName: String

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                PlatformUploadingContent(width: min(312, max(0, geometry.size.width - 40)), platformName: platformName)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct PlatformUploadingContent: View {
    var width: CGFloat = 312
    var platformName: String = "플랫폼"
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var messageLineHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 8) {
            Text("업로드 중...")
                .font(.custom("Pretendard-Bold", fixedSize: titleSize))
                .tracking(-0.26)
                .frame(minHeight: titleLineHeight)
                .accessibilityLabel("\(platformName)에 업로드 중")
                .accessibilityModalHeading()
            UploadLoadingAnimation(width: max(0, width - 32), height: max(0, width - 32))
            Text("자동으로 업로드하고 있어요!\n조금만 기다려 주세요")
                .font(.custom("Pretendard-Regular", fixedSize: messageSize))
                .tracking(-0.43)
                .lineSpacing(max(0, messageLineHeight - (UIFont(name: "Pretendard-Regular", size: messageSize)?.lineHeight ?? messageSize)))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: messageLineHeight * 2)
        }
        .foregroundStyle(Color("BrandNeutralBlack"))
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .padding(16)
        .frame(width: width)
        .background {
            RoundedRectangle(cornerRadius: 44, style: .circular)
                .fill(Color(.brandNeutralWhite))
        }
        .clipShape(RoundedRectangle(cornerRadius: 44, style: .circular))
        .shadow(color: .black.opacity(0.25), radius: 4)
    }
}

#Preview("업로드 중") {
    Color.white.ignoresSafeArea()
        .overlay { PlatformUploadingOverlay(platformName: "인스타그램") }
}

#Preview("업로드 중 · 콘텐츠", traits: .sizeThatFitsLayout) {
    PlatformUploadingContent()
        .frame(width: 402)
        .padding(.vertical)
        .background(Color.black.opacity(0.6))
}
