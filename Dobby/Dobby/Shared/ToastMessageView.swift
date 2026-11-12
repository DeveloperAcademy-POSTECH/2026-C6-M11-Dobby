import SwiftUI

struct ToastMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(message)
                .font(.custom("Pretendard-SemiBold", fixedSize: 16))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 8)
        .frame(width: 318, height: 52, alignment: .leading)
        .background(Color("BrandNeutral900"))
        .cornerRadius(8)
    }
}

#Preview("제품명 복사") {
    ToastMessageView(message: "제품명을 복사했어요")
}
