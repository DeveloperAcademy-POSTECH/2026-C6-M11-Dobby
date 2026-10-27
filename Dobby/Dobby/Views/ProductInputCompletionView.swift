import SwiftUI

struct ProductInputCompletionView: View {
    let garment: Garment
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        ScrollView {
            ProductCompletionContent(garment: garment)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(ProductInformationStyle.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProductCompletionActions(onExport: onExport, onLibrary: onLibrary)
        }
        .navigationTitle("제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ProductInformationStyle.background, for: .navigationBar)
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
            ProductDetailCard(garment: garment, photoPresentation: .compact)
        }
    }
}

private struct ProductCompletionHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("제품 정보 입력 완료! 🎉").font(.system(size: 20, weight: .bold))
            Text("보관함에서 저장한 옷을 확인할 수 있어요")
                .font(.system(size: 16, weight: .medium))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct ProductCompletionActions: View {
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ProductUploadButton(action: onExport)
            .accessibilityIdentifier("product-complete.export")
            Button(action: onLibrary) {
                Text("보관함으로 이동하기").frame(maxWidth: .infinity).frame(height: 62)
                    .foregroundStyle(Color(red: 69 / 255, green: 33 / 255, blue: 7 / 255))
                    .background(Color(red: 248 / 255, green: 241 / 255, blue: 237 / 255), in: Capsule())
            }
            .accessibilityIdentifier("product-complete.library")
        }
        .font(.callout.weight(.semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 33)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .background(ProductInformationStyle.background.ignoresSafeArea(edges: .bottom))
    }
}

struct ProductUploadButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("플랫폼에 업로드하러 가기")
                .font(.callout.weight(.semibold).italic())
                .tracking(-0.31)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(ProductInformationStyle.upload, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
