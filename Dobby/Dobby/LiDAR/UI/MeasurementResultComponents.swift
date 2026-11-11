import SwiftUI
import UIKit

/// The same measured values drive the photo labels and this display-only summary.
/// Figma's sample garment names and numbers never enter the result data model.
struct MeasurementResultSummary: View {
    let values: [MeasurementValue]
    let isRecalculating: Bool
    let overlaysPhoto: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 75
    @ScaledMetric(relativeTo: .body) private var titleLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .callout) private var valueLineHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .subheadline) private var guidanceLineHeight: CGFloat = 20

    private var displayedValues: [MeasurementValue] {
        // The caller already supplies visible values. Reorder only the known
        // top fields for this screen; preserve every bottom/unknown value and
        // its relative order without changing the shared export presentation.
        let topOrder = ["top.shoulderWidth", "top.chestWidth", "top.totalLength",
                        "top.frontLength", "top.sleeveLengthLeft"]
        return values.enumerated().sorted { lhs, rhs in
            let left = topOrder.firstIndex(of: lhs.element.id) ?? topOrder.count
            let right = topOrder.firstIndex(of: rhs.element.id) ?? topOrder.count
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    private var guidanceColor: Color {
        // A reduced-transparency sheet is an opaque light surface, so its
        // guidance must use the same dark text as the white result footer.
        overlaysPhoto && !reduceTransparency ? .white : Color("BrandNeutral800")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("측정점을 움직여서 원하는 부분의 실측 사이즈를 알 수 있어요")
                .font(.custom("Pretendard-SemiBold", size: 14, relativeTo: .subheadline))
                .tracking(-0.23)
                .foregroundStyle(guidanceColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: guidanceLineHeight)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("garmentResultSummaryGuidance")

            if displayedValues.isEmpty {
                Text(isRecalculating ? "측정 중이에요" : "표시할 측정값이 없어요")
                    .font(.custom("Pretendard-Regular", size: 16, relativeTo: .callout))
                    .foregroundStyle(guidanceColor)
                    .frame(maxWidth: .infinity, minHeight: cardHeight)
                    .accessibilityIdentifier("garmentResultEmptySummary")
            } else {
                cards
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentResultMeasurementSummary")
    }

    private var cards: some View {
        GeometryReader { geometry in
            let count = displayedValues.count
            let spacing: CGFloat = count >= 5 ? 6 : 8
            let preferredWidth: CGFloat = count >= 5 ? 68 : 83
            if count > 5 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(displayedValues) { value in
                            card(value).frame(width: preferredWidth)
                        }
                    }
                }
                .accessibilityIdentifier("garmentResultScrollableMeasurementCards")
            } else {
                let available = max(0, geometry.size.width - CGFloat(count - 1) * spacing)
                let width = min(preferredWidth, available / CGFloat(max(count, 1)))
                HStack(spacing: spacing) {
                    ForEach(displayedValues) { value in
                        card(value).frame(width: width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: cardHeight)
    }

    private func card(_ value: MeasurementValue) -> some View {
        VStack(spacing: 6) {
            Text(title(for: value))
                .font(.custom("Pretendard-Regular", size: 17, relativeTo: .body))
                .tracking(-0.43)
                .foregroundStyle(.black.opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: titleLineHeight)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(displayText(for: value))
                // The design's Callout/Emphasized style is Semibold Italic.
                // Use the bundled Semibold face with SwiftUI's italic trait.
                .font(.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout).italic())
                .tracking(-0.31)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: valueLineHeight)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 4)
        .frame(height: cardHeight)
        .background(Color("BrandNeutral100"), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title(for: value))
        .accessibilityValue(accessibilityValue(for: value))
        .accessibilityIdentifier("garmentResultMeasurementCard_\(value.id)")
    }

    private func title(for value: MeasurementValue) -> String {
        let title = GarmentMeasurementPresentation.overlayTitle(for: value.id, fallback: value.title)
        return GarmentMeasurementPresentation.shortTitle(for: value.id, fallback: title)
    }

    private func displayText(for value: MeasurementValue) -> String {
        guard !isRecalculating, value.hasUsableMeasurement,
              let meters = value.meters else { return "—" }
        return MeasurementDisplayText.centimeters(meters * 100) + "cm"
    }

    private func accessibilityValue(for value: MeasurementValue) -> String {
        if isRecalculating { return "측정점을 반영하여 다시 측정 중" }
        guard value.hasUsableMeasurement else {
            return value.failureFeedback.map { "측정 불가. \($0.reason) \($0.recovery)" } ?? "측정 불가"
        }
        return displayText(for: value)
    }
}

/// Figma's four-part Progress Bar, with the result screen on its second stage.
struct MeasurementResultProgress: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4) { index in
                Rectangle()
                    .fill(Color(index < 2 ? "BrandMain500" : "BrandNeutral200"))
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: index == 0 ? 0 : 22,
                        bottomLeadingRadius: index == 0 ? 0 : 22,
                        bottomTrailingRadius: index == 3 ? 0 : 22,
                        topTrailingRadius: index == 3 ? 0 : 22))
            }
        }
        .frame(height: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("촬영 및 등록 진행 단계")
        .accessibilityValue("4단계 중 2단계, 실측 결과")
        .accessibilityIdentifier("garmentResultProgress")
    }
}

/// A frosted sheet, not Liquid Glass: the photo stays under a single blur layer.
struct MeasurementResultSheetBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color("BrandNeutral100")
            } else {
                MeasurementResultBlur()
                Color(.sRGB, red: 148.0 / 255, green: 148.0 / 255,
                      blue: 148.0 / 255, opacity: 0.6)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct MeasurementResultBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialLight))
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}
