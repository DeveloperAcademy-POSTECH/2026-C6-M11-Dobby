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

private struct FruitsCopyCard: View {
    let product: ExportProduct
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FruitsCopyFieldView(
                field: .productName,
                value: product.marketplacePayload.productName,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .description,
                value: product.marketplacePayload.description,
                valueHeight: 100,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .brand,
                value: product.marketplacePayload.brand,
                onCopy: onCopy
            )
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutral100"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FruitsCopyFieldView: View {
    let field: ProductCopyField
    let value: String
    var valueHeight: CGFloat? = nil
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        Button {
            onCopy(field)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: "document.on.document")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color("BrandPrimary100"))
                }
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(field == .description ? 6 : 2)
                    .frame(maxWidth: .infinity, minHeight: valueHeight, alignment: .topLeading)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) 복사")
        .accessibilityValue(value)
    }

    private var title: String {
        switch field {
        case .productName: "제품명"
        case .description: "설명"
        case .brand: "브랜드"
        case .measurements: "실측 사이즈"
        }
    }
}
