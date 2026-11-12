import SwiftUI

struct ExportChannelListView: View {
    let completedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(.brandNeutral600))

            VStack(spacing: 10) {
                ForEach(channels) { channel in
                    ExportChannelButton(channel: channel, isComplete: completedChannels.contains(channel)) {
                        onSelectChannel(channel)
                    }
                }
            }
        }
    }
}

#Preview("업로드 채널", traits: .sizeThatFitsLayout) {
    ExportChannelListView(completedChannels: [], onSelectChannel: { _ in })
        .padding(30)
}

#Preview("자동 업로드 섹션", traits: .sizeThatFitsLayout) {
    ExportChannelSection(
        title: "자동 업로드",
        channels: [.instagram, .cafe24],
        completedChannels: [.instagram],
        onSelectChannel: { _ in }
    )
    .frame(width: 337)
    .padding()
    .background(Color(.brandNeutralWhite))
}

#Preview("복사해서 옮기기 섹션", traits: .sizeThatFitsLayout) {
    ExportChannelSection(
        title: "복사해서 옮기기",
        channels: [.fruitsFamily],
        completedChannels: [],
        onSelectChannel: { _ in }
    )
    .frame(width: 337)
    .padding()
    .background(Color(.brandNeutralWhite))
}
