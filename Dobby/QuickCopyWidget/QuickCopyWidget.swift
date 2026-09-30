import SwiftUI
import WidgetKit
import ActivityKit

@main
struct QuickCopyWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProductCopyAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                header(context.attributes.channelName)
                ProductCopyPanel(sessionID: context.attributes.sessionID, mode: context.attributes.mode)
                Text(context.state.message).font(.caption2).foregroundStyle(.white.opacity(0.8))
            }.padding().activityBackgroundTint(.black)
                .widgetURL(CopyRoute.home)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Dobby").font(.caption).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Circle().fill(.mint).frame(width: 5, height: 5).accessibilityLabel("복사 도우미 활성")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProductCopyPanel(sessionID: context.attributes.sessionID, mode: context.attributes.mode)
                        Text(context.state.message).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
            } compactLeading: { Image(systemName: "doc.on.doc").foregroundStyle(.orange) }
              compactTrailing: { Text("복사").foregroundStyle(.white) }
              minimal: { Image(systemName: "doc.on.doc").foregroundStyle(.orange) }
                .widgetURL(CopyRoute.home)
        }
    }
    private func header(_ channel: String) -> some View {
        HStack {
            Text("Dobby · \(channel)").font(.caption).foregroundStyle(.white)
            Spacer()
            Circle().fill(.mint).frame(width: 5, height: 5).accessibilityLabel("복사 도우미 활성")
        }
    }
}

#Preview("확장 Island", as: .dynamicIsland(.expanded), using: ProductCopyAttributes(sessionID: UUID(), channelName: "후르츠패밀리", mode: .foreground)) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("잠금 화면", as: .content, using: ProductCopyAttributes(sessionID: UUID(), channelName: "후르츠패밀리", mode: .foreground)) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("작은 Island", as: .dynamicIsland(.compact), using: ProductCopyAttributes(sessionID: UUID(), channelName: "후르츠패밀리", mode: .foreground)) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }
