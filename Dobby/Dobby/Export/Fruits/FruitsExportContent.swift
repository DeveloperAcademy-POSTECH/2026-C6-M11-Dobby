import SwiftUI

struct FruitsExportContent: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("복사 버튼을 누르고\n후루츠패밀리 판매 페이지를 열어주세요")
                .font(.custom("Pretendard-Bold", size: 22, relativeTo: .title2))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 41)

            FruitsCopyCard(product: product, onCopy: onCopy)

            Text("판매 페이지를 열고 제품명, 설명, 브랜드를 붙여넣어 주세요\n • 실측 사이즈는 화면에 뜬 PIP를 보고 입력해 주세요")
                .font(.custom("Pretendard-Regular", fixedSize: 14))
                .foregroundStyle(Color("BrandNeutral500"))
        }
        .padding(.top, 25)
        .padding(.horizontal, 20)
        .frame(maxWidth: 402)
        .frame(maxWidth: .infinity)
        .background(Color(.brandNeutralWhite))
    }
}

#Preview("기본") {
    FruitsExportContent(product: .fruitsPreview, onCopy: { _ in })
}

#Preview("긴 내용") {
    FruitsExportContent(product: .fruitsLongPreview, onCopy: { _ in })
}
