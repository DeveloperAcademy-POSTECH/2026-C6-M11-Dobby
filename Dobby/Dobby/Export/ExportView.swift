import SwiftUI

struct ExportView: View {
    @Environment(\.dismiss) private var dismiss

    let openedChannels: Set<ExportChannel>
    let onSelectChannel: (ExportChannel) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                ExportChannelListView(
                    openedChannels: openedChannels,
                    onSelectChannel: onSelectChannel
                )
                .frame(maxWidth: 540)
                .padding(.horizontal, 30)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ExportHeaderView {
                dismiss()
            }
        }
        .background(Color.white)
        .preferredColorScheme(.light)
    }
}

#Preview("처음 방문") {
    ExportView(openedChannels: [], onSelectChannel: { _ in })
}

#Preview("Instagram 방문") {
    ExportView(openedChannels: [.instagram], onSelectChannel: { _ in })
}

#Preview("모든 채널 방문") {
    ExportView(openedChannels: Set(ExportChannel.allCases), onSelectChannel: { _ in })
}

#Preview("작은 화면 · 큰 글자", traits: .fixedLayout(width: 320, height: 568)) {
    ExportView(openedChannels: [.instagram], onSelectChannel: { _ in })
        .environment(\.dynamicTypeSize, .accessibility3)
}
