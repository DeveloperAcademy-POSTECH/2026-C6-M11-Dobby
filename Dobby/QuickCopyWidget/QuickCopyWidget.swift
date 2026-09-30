import SwiftUI
import WidgetKit
import ActivityKit

@main
struct QuickCopyWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProductCopyAttributes.self) { context in
            VStack {
                Text("Dobby · \(context.attributes.channelName)")
                Text(context.state.message)
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.message) }
            } compactLeading: { Image(systemName: "doc.on.doc") }
              compactTrailing: { Text("복사") }
              minimal: { Image(systemName: "doc.on.doc") }
        }
    }
}
