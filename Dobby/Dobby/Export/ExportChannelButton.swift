import SwiftUI

struct ExportChannelButton: View {

    let channel: ExportChannel
    let isComplete: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                Text(channel.shortTitle)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if isComplete {
                    Text("완료")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.brandMain))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.brandMain).opacity(0.12), in: Capsule())
                }
            }
            .padding(16)
            .frame(minHeight: 80)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.shortTitle)
        .accessibilityValue(isComplete ? "업로드 완료" : "업로드 전")
    }
}

#Preview("방문 전", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, isComplete: false, action: {})
        .padding()
}

#Preview("방문 후", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, isComplete: true, action: {})
        .padding()
}

#Preview("카페24", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .cafe24, isComplete: false, action: {})
        .padding()
}

#Preview("후루츠패밀리", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .fruitsFamily, isComplete: false, action: {})
        .padding()
}
