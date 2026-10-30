import SwiftUI

struct FruitsTransferIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("FruitsExportSourceMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28.46, height: 8)
                .frame(width: 31, height: 31)
                .background(Color("BrandSub100"), in: RoundedRectangle(cornerRadius: 8))
            Image("FruitsExportArrow")
                .resizable()
                .frame(width: 13.5, height: 11)
            Image("FruitsFamailyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 31, height: 31)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dobby에서 후루츠패밀리로 내보내기")
    }
}

#Preview {
    FruitsTransferIndicator()
        .padding()
}
