import SwiftUI

struct FruitsCopyFeedbackView: View {
    var body: some View {
        Text("복사했어요")
            .font(.custom("Pretendard-Medium", fixedSize: 12))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .frame(width: 127, height: 22)
            .background(Color("BrandNeutral500"))
            .clipShape(.rect(cornerRadius: 25))
    }
}

#Preview {
    FruitsCopyFeedbackView()
}
