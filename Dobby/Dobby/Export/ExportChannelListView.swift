import SwiftUI

struct ExportChannelListView: View {
    let openedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void
    var openedFruitsMethods: Set<FruitsExportMethod> = []
    var onSelectFruits: ((FruitsExportMethod) -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            ForEach(ExportChannel.availableCases) { channel in
                if channel == .fruitsFamily, let onSelectFruits {
                    ForEach(FruitsExportMethod.allCases) { method in
                        ExportChannelButton(channel: channel,
                                            hasOpenedLink: openedFruitsMethods.contains(method),
                                            action: { onSelectFruits(method) },
                                            titleOverride: method.title)
                    }
                } else {
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
