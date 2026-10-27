import SwiftUI

struct PlatformUploadingOverlay: View {
    let platformName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            PlatformUploadingContent(platformName: platformName)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(platformName)에 업로드 중입니다. 조금만 기다려 주세요.")
    }
}

private struct PlatformUploadingContent: View {
    let platformName: String

    var body: some View {
        VStack(spacing: 0) {
            Text("업로드 중...")
                .font(.custom("Pretendard-Bold", fixedSize: 20))
            Spacer(minLength: 0)
            UploadLoadingAnimation()
            Spacer(minLength: 0)
            Text("\(platformName)에 자동으로 업로드하고 있어요!\n조금만 기다려 주세요")
                .font(.custom("Pretendard-Regular", fixedSize: 16))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(.brandNeutral900))
        .padding(.vertical, 24)
        .frame(width: 360, height: 270)
        .background(Color(.brandNeutralWhite), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
}
