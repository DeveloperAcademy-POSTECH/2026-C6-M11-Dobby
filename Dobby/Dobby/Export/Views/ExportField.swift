import SwiftUI

struct ExportField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ExportScreenStyle.label)
            content
        }
    }
}

struct ExportTextFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
    }
}

extension View {
    func exportTextFieldStyle() -> some View {
        modifier(ExportTextFieldBackground())
    }
}

#Preview("입력 필드", traits: .sizeThatFitsLayout) {
    ExportField(label: "상품명") {
        TextField("상품명을 입력해 주세요", text: .constant("90s 나이키 자켓"))
            .exportTextFieldStyle()
    }
    .frame(width: 363)
    .padding()
    .background(ExportScreenStyle.background)
}
