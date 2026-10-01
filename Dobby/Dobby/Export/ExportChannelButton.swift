import SwiftUI

struct ExportChannelButton: View {

    let channel: ExportChannel
    let hasOpenedLink: Bool
    let action: () -> Void
    var titleOverride: String? = nil

    var body: some View {
        Button(action: action) {
            HStack(spacing: 19) {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                Text(titleOverride ?? channel.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Image(systemName: "checkmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                    .opacity(hasOpenedLink ? 1 : 0)
            }
            .padding(20)
            .background(Color(.backgroundNomalAlternative), in: RoundedRectangle(cornerRadius: 28))
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(titleOverride ?? channel.title)
        .accessibilityValue(hasOpenedLink ? "열어본 채널" : "아직 열지 않은 채널")
    }
}

#Preview("방문 전", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, hasOpenedLink: false, action: {})
        .padding()
}

#Preview("방문 후", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, hasOpenedLink: true, action: {})
        .padding()
}

#Preview("네이버스토어", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .naverStore, hasOpenedLink: false, action: {})
        .padding()
}

#Preview("카페24", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .cafe24, hasOpenedLink: false, action: {})
        .padding()
}

#Preview("후루츠패밀리", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .fruitsFamily, hasOpenedLink: false, action: {})
        .padding()
}
