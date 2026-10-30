import SwiftUI

struct FruitsExportContent: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("복사 버튼을 누르고\n후루츠패밀리 판매 페이지를 열어주세요")
                    .font(.custom("Pretendard-Bold", fixedSize: 22))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 40)
                    .padding(.bottom, 14)

                FruitsCopyCard(product: product, onCopy: onCopy)

                Text("판매 페이지를 열고 제품명, 설명, 브랜드를 붙여 넣어주세요")
                    .padding(.top, 14)
                Text("· 실측 사이즈는 화면에 뜬 PiP를 보고 입력해 주세요")
                    .padding(.top, 4)
            }
            .font(.custom("Pretendard-Medium", fixedSize: 14))
            .foregroundStyle(Color("BrandNeutral500"))
            .padding(.horizontal, 21)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(.white)
    }
}

#Preview("기본") {
    FruitsExportContent(product: .fruitsPreview, onCopy: { _ in })
}

#Preview("긴 내용") {
    FruitsExportContent(product: .fruitsLongPreview, onCopy: { _ in })
}
