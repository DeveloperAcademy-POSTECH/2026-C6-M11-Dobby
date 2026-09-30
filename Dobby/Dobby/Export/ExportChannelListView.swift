import SwiftUI

struct ExportChannelListView: View {
    let openedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ForEach(ExportChannel.allCases) { channel in
                ExportChannelButton(
                    channel: channel,
                    hasOpenedLink: openedChannels.contains(channel)
                ) {
                    onSelectChannel(channel)
                }
            }
        }
    }
}

#Preview("처음 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(openedChannels: [], onSelectChannel: { _ in })
        .padding(30)
}

#Preview("일부 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(openedChannels: [.instagram], onSelectChannel: { _ in })
        .padding(30)
}

#Preview("모두 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(openedChannels: Set(ExportChannel.allCases), onSelectChannel: { _ in })
        .padding(30)
}
