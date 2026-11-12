import SwiftUI

struct ExportInfoBanner: View {
    let text: String
    var systemImage = "info.circle.fill"
    var tint: Color = ExportScreenStyle.accent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
    }
}
