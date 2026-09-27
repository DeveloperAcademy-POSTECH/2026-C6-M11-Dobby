import SwiftUI

struct ExportChannelListView: View {
    let openedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(spacing: 36) {
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
