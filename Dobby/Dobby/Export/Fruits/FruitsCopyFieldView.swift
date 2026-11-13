import SwiftUI

struct FruitsCopyFieldView: View {
    let field: ProductCopyField
    let value: String
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        Button {
            onCopy(field)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.labelPrimary)
                    Spacer()
                    Image("ci:copy")
                        .renderingMode(.template)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(Color("BrandNeutralBlack"))
                }
                Text(value)
                    .font(.system(size: 15))
                    .foregroundColor(.labelPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(field == .description ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: 328, alignment: .topLeading)
            .foregroundStyle(.primary)
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

#Preview("제품명") {
    FruitsCopyFieldView(
        field: .productName,
        value: "LEVI'S 550 보로 사시코 커스텀 팬츠",
        onCopy: { _ in }
    )
    .padding(.horizontal, 16)
}

#Preview("긴 설명") {
    FruitsCopyFieldView(
        field: .description,
        value: "빈티지한 워싱과 자연스러운 실루엣이 돋보이는 제품입니다. 사용감과 수선 흔적까지 상품의 상태를 충분히 확인할 수 있도록 긴 설명이 모두 표시되는지 확인합니다.",
        onCopy: { _ in }
    )
    .padding(.horizontal, 16)
}

#Preview("브랜드") {
    FruitsCopyFieldView(
        field: .brand,
        value: "LEVI'S",
        onCopy: { _ in }
    )
    .padding(.horizontal, 16)
}
