import SwiftUI

struct ExportChannelButton: View {
    let channel: ExportChannel
    let hasOpenedLink: Bool
    let action: () -> Void
    var titleOverride: String? = nil

    var body: some View {
        ChakPrimaryButton(
            title: titleOverride ?? channel.title,
            showsCompletion: hasOpenedLink
        ) {
            action()
        }
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

#Preview("카페24", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .cafe24, hasOpenedLink: false, action: {})
        .padding()
}

#Preview("후루츠패밀리", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .fruitsFamily, hasOpenedLink: false, action: {})
        .padding()
}
