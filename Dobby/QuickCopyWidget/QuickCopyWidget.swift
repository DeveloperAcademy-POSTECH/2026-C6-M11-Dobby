import SwiftUI
import WidgetKit
import ActivityKit

@main
struct QuickCopyWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProductCopyAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                header(context.attributes.channelName)
                ProductCopyPanel(sessionID: context.attributes.sessionID, values: context.attributes.values)
                Text(context.state.message).font(.caption2).foregroundStyle(.white.opacity(0.8))
            }.padding().activityBackgroundTint(.black)
                .widgetURL(URL(string: "dobby-copy://home")!)
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
                        ProductCopyPanel(sessionID: context.attributes.sessionID, values: context.attributes.values)
                        Text(context.state.message).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
            } compactLeading: { Image(systemName: "doc.on.doc").foregroundStyle(.orange) }
              compactTrailing: { Text("복사").foregroundStyle(.white) }
              minimal: { Image(systemName: "doc.on.doc").foregroundStyle(.orange) }
                .widgetURL(URL(string: "dobby-copy://home")!)
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

#Preview("Default", as: .dynamicIsland(.expanded), using: defaultPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("후루츠패밀리 · 상의", as: .dynamicIsland(.expanded), using: topPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("후루츠패밀리 · 바지", as: .dynamicIsland(.expanded), using: pantsPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("후루츠패밀리 · 일부 실측", as: .dynamicIsland(.expanded), using: partialPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("잠금 화면", as: .content, using: pantsPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

#Preview("작은 Island", as: .dynamicIsland(.compact), using: pantsPreviewAttributes) {
    QuickCopyWidget()
} contentStates: { ProductCopyAttributes.ContentState() }

private let defaultPreviewAttributes = previewAttributes()

private let topPreviewAttributes = previewAttributes(measurements: [
    .init(id: "shoulder", title: "어깨", value: "56"),
    .init(id: "chest", title: "가슴", value: "55"),
    .init(id: "length", title: "기장", value: "68"),
    .init(id: "sleeve", title: "소매", value: "52")
])

private let pantsPreviewAttributes = previewAttributes(measurements: [
    .init(id: "length", title: "총장", value: "56"),
    .init(id: "waist", title: "허리", value: "55"),
    .init(id: "hip", title: "엉덩이", value: "68"),
    .init(id: "thigh", title: "허벅지", value: "68"),
    .init(id: "rise", title: "밑위", value: "52"),
    .init(id: "hem", title: "밑단", value: "52")
])

private let partialPreviewAttributes = previewAttributes(measurements: [
    .init(id: "length", title: "총장", value: "59"),
    .init(id: "waist", title: "허리 단면", value: "43"),
    .init(id: "thigh", title: "허벅지 단면", value: "32")
])

private func previewAttributes(measurements: [ProductCopyMeasurement]? = nil) -> ProductCopyAttributes {
    ProductCopyAttributes(
        sessionID: UUID(),
        channelName: "후루츠패밀리",
        values: .init(
            productName: "LEVI'S 550 커스텀 팬츠",
            description: "상품 설명",
            brand: "LEVI'S",
            measurements: "총장 59 cm",
            measurementItems: measurements,
            price: "56000"
        )
    )
}
