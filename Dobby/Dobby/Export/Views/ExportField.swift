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
