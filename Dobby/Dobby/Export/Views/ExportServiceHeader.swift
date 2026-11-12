import SwiftUI

struct ExportServiceHeader: View {
    let channel: ExportChannel
    let title: String
    let description: String
    var status: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(channel.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    if let status {
                        ExportStatusBadge(title: status)
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(ExportScreenStyle.card, in: RoundedRectangle(cornerRadius: ExportScreenStyle.cardCornerRadius))
    }
}

struct ExportStatusBadge: View {
    let title: String
    var color: Color = ExportScreenStyle.accent

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

#Preview("서비스 헤더", traits: .sizeThatFitsLayout) {
    ExportServiceHeader(
        channel: .instagram,
        title: "인스타그램",
        description: "프로페셔널 계정으로 상품 사진과 캡션을 업로드해요.",
        status: "연결됨"
    )
    .frame(width: 363)
    .padding()
    .background(ExportScreenStyle.background)
}

#Preview("상태 배지", traits: .sizeThatFitsLayout) {
    ExportStatusBadge(title: "연결됨")
        .padding()
        .background(Color(.brandNeutralWhite))
}
