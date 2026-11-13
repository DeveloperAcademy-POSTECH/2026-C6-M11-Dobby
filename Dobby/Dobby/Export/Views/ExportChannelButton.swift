import SwiftUI

struct ExportChannelButton: View {

    let channel: ExportChannel
    let isComplete: Bool
    let action: () -> Void

    private var showsCompletionStatus: Bool {
        channel == .instagram || channel == .cafe24
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Image(channel.imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 15))

                Text(channel.shortTitle)
                    .font(.callout.weight(.regular))
                    .foregroundStyle(Color(.brandNeutralBlack))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if showsCompletionStatus && isComplete {
                    Text("완료")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(.brandNeutral50))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.brandMain500), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(channel.shortTitle)
        .accessibilityValue(showsCompletionStatus ? (isComplete ? "업로드 완료" : "업로드 전") : "")
    }
}

#Preview("방문 전", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, isComplete: false, action: {})
        .padding()
}

#Preview("방문 후", traits: .sizeThatFitsLayout) {
    ExportChannelButton(channel: .instagram, isComplete: true, action: {})
        .padding()
}
