import SwiftUI

struct FruitsTransferIndicator: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("DobbyAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 31, height: 31)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Image("FruitsExportArrow")
                .resizable()
                .frame(width: 14, height: 11)
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
