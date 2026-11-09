import SwiftUI

struct PlatformUploadingOverlay: View {
    let platformName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            PlatformUploadingContent()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(platformName)에 업로드 중입니다. 조금만 기다려 주세요.")
    }
}

private struct PlatformUploadingContent: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("업로드 중...")
                .font(.custom("Pretendard-Bold", fixedSize: 20))
                .foregroundStyle(.black)
            UploadLoadingAnimation(width: 280, height: 280)
            Text("자동으로 업로드하고 있어요!\n조금만 기다려 주세요")
                .font(.custom("Pretendard-Regular", fixedSize: 16))
                .foregroundStyle(.black)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 12)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.brandNeutralWhite))
                .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 0)
        }
        .padding(.horizontal, 16)
    }
}
