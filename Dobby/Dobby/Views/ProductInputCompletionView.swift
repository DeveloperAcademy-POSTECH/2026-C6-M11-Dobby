import SwiftUI
import SwiftData

struct ProductInputCompletionView: View {
    let garment: Garment
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ProductCompletionHeader()
                    .padding(.bottom, 40)

                ScrollView(.vertical) {
                    ProductDetailCard(garment: garment, style: .completion)
                }
                .frame(maxWidth: 363)
                .frame(height: min(472, max(0, geometry.size.height - 174)))
                .background(Color("BrandNeutralWhite"))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .circular))
                .accessibilityIdentifier("product-complete.details-scroll")

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color("BrandNeutral50"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProductCompletionActions(onExport: onExport, onLibrary: onLibrary)
                .padding(.horizontal, 33.5)
                .padding(.top, 16)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .background(Color("BrandNeutral50").ignoresSafeArea(edges: .bottom))
        }
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                Color("BrandNeutral50")
                    .frame(height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("product-complete.screen")
    }
}

private struct ProductCompletionHeader: View {
    @AccessibilityFocusState(for: .voiceOver) private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("제품 정보 입력 완료 🎉")
                .font(.custom("Pretendard-Bold", size: 28, relativeTo: .title))
                .tracking(0.38)
                .frame(minHeight: 34)
                .accessibilityLabel("제품 정보 입력 완료")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Text("보관함에서 저장한 옷을 확인할 수 있어요")
                .font(.custom("Pretendard-Regular", size: 17, relativeTo: .body))
                .tracking(-0.43)
                .frame(minHeight: 22)
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
                    .tracking(-0.31)
            }
            .buttonStyle(ChakPrimaryButtonStyle(variant: .solid))
            .accessibilityIdentifier("product-complete.export")
            .accessibilityHint("저장한 제품의 업로드 채널 선택 화면을 엽니다")
            Button(action: onLibrary) {
                Text("보관함으로 이동하기")
                    .font(.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout))
                    .tracking(-0.31)
                    .foregroundStyle(Color(red: 69 / 255, green: 33 / 255, blue: 7 / 255))
            }
            .buttonStyle(ChakPrimaryButtonStyle(variant: .tonal))
            .accessibilityIdentifier("product-complete.library")
            .accessibilityHint("완료한 제품을 저장하고 보관함으로 이동합니다")
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview("제품 정보 입력 완료") {
    NavigationStack {
        ProductInputCompletionView(
            garment: SampleData.first(in: SampleData.previewContainer.mainContext),
            onExport: {},
            onLibrary: {}
        )
    }
    .modelContainer(SampleData.previewContainer)
    .preferredColorScheme(.light)
}
#endif
