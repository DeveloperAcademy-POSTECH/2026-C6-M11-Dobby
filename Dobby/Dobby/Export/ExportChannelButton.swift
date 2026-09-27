import SwiftUI

struct ExportChannelButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let channel: ExportChannel
    let hasOpenedLink: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 44 : 64, height: dynamicTypeSize.isAccessibilitySize ? 44 : 64)
                    .accessibilityHidden(true)
                Text(channel.title)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                Image(systemName: "checkmark")
                    .font(.title3.weight(.regular))
                    .frame(width: 24)
                    .opacity(hasOpenedLink ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.black)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(Color(red: 0.95, green: 0.95, blue: 0.97), in: RoundedRectangle(cornerRadius: 28))
            .contentShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.title)
        .accessibilityValue(hasOpenedLink ? "열어본 링크" : "아직 열지 않은 링크")
        .accessibilityIdentifier("export.channel.\(channel.rawValue)")
    }
}
