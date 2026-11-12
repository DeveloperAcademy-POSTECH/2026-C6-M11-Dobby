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
    var body: some View {
        VStack(spacing: 12) {
            Text("제품 정보 입력 완료! 🎉")
                .font(.custom("Pretendard-SemiBold", size: 20, relativeTo: .title3))
                .frame(minHeight: 25)
            Text("보관함에서 저장한 옷을 확인할 수 있어요")
                .font(.custom("Pretendard-Regular", size: 16, relativeTo: .callout))
                .frame(minHeight: 20)
        }
        .foregroundStyle(Color("BrandNeutralBlack"))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
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
            Button(action: onLibrary) {
                Text("보관함으로 이동하기")
                    .font(.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout))
                    .foregroundStyle(Color(red: 69 / 255, green: 33 / 255, blue: 7 / 255))
            }
            .buttonStyle(ChakPrimaryButtonStyle(variant: .tonal))
            .accessibilityIdentifier("product-complete.library")
        }
        .frame(maxWidth: .infinity)
    }
}
