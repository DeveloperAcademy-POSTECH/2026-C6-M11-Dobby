import SwiftUI

struct ExportChannelListView: View {
    let completedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ExportChannelSection(title: "자동 업로드", channels: [.instagram, .cafe24],
                                 completedChannels: completedChannels, onSelectChannel: onSelectChannel)
            ExportChannelSection(title: "복사해서 옮기기", channels: [.fruitsFamily],
                                 completedChannels: completedChannels, onSelectChannel: onSelectChannel)
        }
    }
}

private struct ExportChannelSection: View {
    let title: String
    let channels: [ExportChannel]
    let completedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            VStack(spacing: 12) {
                ForEach(channels) { channel in
                    ExportChannelButton(channel: channel, isComplete: completedChannels.contains(channel)) {
                        onSelectChannel(channel)
                    }
                }
            }
        }
    }
}

#Preview("처음 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(completedChannels: [], onSelectChannel: { _ in })
        .padding(30)
}

#Preview("일부 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(completedChannels: [.instagram], onSelectChannel: { _ in })
        .padding(30)
}

#Preview("모두 방문", traits: .sizeThatFitsLayout) {
    ExportChannelListView(completedChannels: Set(ExportChannel.availableCases), onSelectChannel: { _ in })
        .padding(30)
}
