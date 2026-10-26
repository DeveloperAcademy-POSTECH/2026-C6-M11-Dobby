import SwiftUI

struct ExportChannelButton: View {

    let channel: ExportChannel
    let isComplete: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)

                Text(channel.shortTitle)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isComplete {
                    Text("완료")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.brandMain))
                }
            }
            .padding(16)
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
