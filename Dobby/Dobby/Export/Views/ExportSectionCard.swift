import SwiftUI

struct ExportSectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportScreenStyle.card, in: RoundedRectangle(cornerRadius: ExportScreenStyle.cardCornerRadius))
    }
}

#Preview("섹션 카드", traits: .sizeThatFitsLayout) {
    ExportSectionCard(title: "캡션", subtitle: "눌러서 직접 글을 수정할 수 있어요") {
        Text("90s 나이키 자켓")
            .frame(maxWidth: .infinity, alignment: .leading)
            .exportTextFieldStyle()
    }
    .frame(width: 363)
    .padding()
    .background(ExportScreenStyle.background)
}
