import SwiftUI

struct ProductAutofillLoadingView: View {
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(ProductInformationStyle.accent)
                Text("AI가 정보 생성 중…").font(.headline)
                Text("사진을 꼼꼼히 보며\n어떤 옷인지 알아보고 있어요")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("취소", action: onCancel)
                    .font(.body.weight(.medium))
                    .tint(.primary)
                    .padding(.top, 4)
                    .accessibilityIdentifier("product-ai.cancel")
            }
            .padding(28)
            .frame(maxWidth: 286)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("product-ai.loading")
        }
    }
}
