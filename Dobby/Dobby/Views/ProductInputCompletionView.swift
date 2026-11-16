import SwiftUI

struct ProductInputCompletionView: View {
    let garment: Garment
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ProductCompletionContent(garment: garment)
                    .padding(.horizontal, 20)
                ProductCompletionActions(onExport: onExport, onLibrary: onLibrary)
                    .padding(.horizontal, 33.5)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Color("BrandNeutral50"))
        .navigationTitle("제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("제품 정보 입력")
                    .font(.custom("Pretendard-SemiBold", size: 17, relativeTo: .headline))
                    .foregroundStyle(Color("BrandNeutralBlack"))
            }
        }
        .toolbarBackground(Color("BrandNeutral50"), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("product-complete.screen")
    }
}

private struct ProductCompletionContent: View {
    let garment: Garment

    var body: some View {
        VStack(spacing: 24) {
            ProductCompletionHeader()
            ProductDetailCard(garment: garment, style: .completion)
        }
    }
}

private struct ProductCompletionHeader: View {
    @AccessibilityFocusState(for: .voiceOver) private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("제품 정보 입력 완료! 🎉")
                .font(.custom("Pretendard-SemiBold", size: 20, relativeTo: .title3))
                .frame(minHeight: 25)
                .accessibilityLabel("제품 정보 입력 완료")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Text("보관함에서 저장한 옷을 확인할 수 있어요")
                .font(.custom("Pretendard-Regular", size: 16, relativeTo: .callout))
                .frame(minHeight: 20)
        }
        .foregroundStyle(Color("BrandNeutralBlack"))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            isTitleFocused = true
        }
    }
}

private struct ProductCompletionActions: View {
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onExport) {
                Text("플랫폼에 업로드하러 가기")
                    .font(.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout))
            }
            .buttonStyle(ChakPrimaryButtonStyle(variant: .solid))
            .accessibilityIdentifier("product-complete.export")
            .accessibilityHint("저장한 제품의 업로드 채널 선택 화면을 엽니다")
            Button(action: onLibrary) {
                Text("보관함으로 이동하기")
                    .font(.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout))
                    .foregroundStyle(Color(red: 69 / 255, green: 33 / 255, blue: 7 / 255))
            }
            .buttonStyle(ChakPrimaryButtonStyle(variant: .tonal))
            .accessibilityIdentifier("product-complete.library")
            .accessibilityHint("완료한 제품을 저장하고 보관함으로 이동합니다")
        }
        .frame(maxWidth: .infinity)
    }
}
