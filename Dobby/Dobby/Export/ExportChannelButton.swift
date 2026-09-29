import SwiftUI

struct ExportChannelButton: View {

    let channel: ExportChannel
    let hasOpenedLink: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 19) {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                Text(channel.title)
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Image(systemName: "checkmark")
                    .font(.callout.weight(.regular))
                    .frame(width: 18)
                    .opacity(hasOpenedLink ? 1 : 0)
            }
            .padding(16)
            .background(Color(.backgroundNomalAlternative), in: RoundedRectangle(cornerRadius: 28))
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
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
