import SwiftUI
import UIKit

/// The same measured values drive the photo labels and this display-only summary.
/// Figma's sample garment names and numbers never enter the result data model.
struct MeasurementResultSummary: View {
    let values: [MeasurementValue]
    let isRecalculating: Bool
    let overlaysPhoto: Bool
    var usesSquareCaptureStyle = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 75
    @ScaledMetric(relativeTo: .body) private var titleLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .callout) private var valueLineHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .subheadline) private var guidanceLineHeight: CGFloat = 20

    private var displayedValues: [MeasurementValue] {
        // The caller already supplies visible values. Reorder only the known
        // top fields for this screen; preserve every bottom/unknown value and
        // its relative order without changing the shared export presentation.
        let topOrder = usesSquareCaptureStyle
            ? ["top.shoulderWidth", "top.chestWidth", "top.totalLength", "top.frontLength", "top.sleeveLengthLeft"]
            : ["top.totalLength", "top.shoulderWidth", "top.chestWidth", "top.frontLength", "top.sleeveLengthLeft"]
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
                .font(valueFont)
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

    private var valueFont: Font {
        let font = Font.custom("Pretendard-SemiBold", size: 16, relativeTo: .callout)
        // The 1:1 design uses upright Callout/Emphasized text; retain the
        // existing italic styling for the other result compositions.
        return usesSquareCaptureStyle ? font : font.italic()
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
        guard let meters = value.meters else { return "측정 불가" }
        return MeasurementDisplayText.centimeters(meters * 100) + " 센티미터"
    }
}

/// Figma's four-part Progress Bar, with the result screen on its second stage.
struct MeasurementResultProgress: View {
    var body: some View {
        ProductCreationProgress(stage: .measurementResult)
        .frame(height: ProductCreationHeaderLayout.progressHeight)
    }
}

/// Own the high-frequency pan state here, outside the photograph and its
/// coordinate/landmark calculations. The frosted surface keeps one fixed size
/// and moves as a unit instead of relaying out and resizing its blur each frame.
struct MeasurementResultSheet: View {
    let values: [MeasurementValue]
    let isRecalculating: Bool
    @Binding var isExpanded: Bool
    let expandedHeight: CGFloat
    let collapsedHeight: CGFloat
    let canvasHeight: CGFloat
    let photoBottom: CGFloat
    let onSummaryHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var gestureIsActive = false
    @State private var drag = SheetDrag()

    private struct SheetDrag {
        let sessionID = UUID()
        var isVertical: Bool?
        var translation: CGFloat = 0
    }

    private var travel: CGFloat { max(0, expandedHeight - collapsedHeight) }
    private var restOffset: CGFloat { isExpanded ? 0 : travel }
    private var visibleOffset: CGFloat { min(travel, max(0, restOffset + drag.translation)) }
    private var visibleHeight: CGFloat { expandedHeight - visibleOffset }
    private var overlaysPhoto: Bool { photoBottom >= canvasHeight - visibleHeight + 48 }
    private var settleAnimation: Animation? { reduceMotion ? nil : .snappy(duration: 0.28) }

    var body: some View {
        ZStack(alignment: .top) {
            MeasurementResultSheetBackdrop()
            MeasurementResultSummary(values: values, isRecalculating: isRecalculating,
                                     overlaysPhoto: overlaysPhoto)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: MeasurementResultSummaryHeightKey.self,
                                               value: geometry.size.height)
                    }
                }
                .onPreferenceChange(MeasurementResultSummaryHeightKey.self, perform: onSummaryHeightChange)
                .padding(.horizontal, values.count >= 5 ? 19 : 23)
                .padding(.top, 28)
                .opacity(min(1, max(0, (visibleHeight - collapsedHeight) / 30)))
                .accessibilityHidden(visibleHeight <= collapsedHeight + 30)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(overlaysPhoto && !reduceTransparency ? Color.white : Color("BrandNeutral800"))
                .frame(width: 38, height: 3).padding(.top, 10.5)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { settle(expanded: !isExpanded) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("실측값 패널")
                .accessibilityValue(isExpanded ? "펼쳐짐" : "접힘")
                .accessibilityHint("두 번 탭해 펼치거나 접습니다. 위아래로 쓸어서도 조절할 수 있어요")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { settle(expanded: !isExpanded) }
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: settle(expanded: true)
                    case .decrement: settle(expanded: false)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("garmentResultSheetHandle")
        }
        .frame(height: expandedHeight, alignment: .top)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        .contentShape(Rectangle())
        .simultaneousGesture(sheetPan)
        .offset(y: visibleOffset)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentResultMeasurementSheet")
        .onChange(of: gestureIsActive) { _, active in
            guard !active, drag.isVertical != nil else { return }
            let session = drag.sessionID
            // A normal onEnded commits first. If the system cancelled the
            // gesture instead, return from the last rendered position without
            // a GestureState reset racing a separate release animation.
            Task { @MainActor in
                guard !gestureIsActive, drag.sessionID == session,
                      drag.isVertical != nil else { return }
                settle(expanded: isExpanded)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { settle(expanded: isExpanded, animated: false) }
        }
        .onChange(of: expandedHeight) { _, _ in settle(expanded: isExpanded, animated: false) }
        .onDisappear { settle(expanded: isExpanded, animated: false) }
    }

    private var sheetPan: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($gestureIsActive) { _, active, transaction in
                transaction.animation = nil
                active = true
            }
            .onChanged { value in
                var next = drag
                if next.isVertical == nil {
                    next.isVertical = abs(value.translation.height) > abs(value.translation.width)
                }
                guard next.isVertical == true else {
                    if drag.isVertical == nil { drag = next }
                    return
                }
                next.translation = min(travel - restOffset, max(-restOffset, value.translation.height))
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { drag = next }
            }
            .onEnded { value in
                guard drag.isVertical == true else {
                    drag = SheetDrag()
                    return
                }
                let projectedOffset = restOffset + value.predictedEndTranslation.height
                settle(expanded: projectedOffset < travel / 2)
            }
    }

    private func settle(expanded: Bool, animated: Bool = true) {
        // Update the rest position and transient translation in one transaction.
        // Neither the original photograph nor its points are moved or rescaled.
        withAnimation(animated ? settleAnimation : nil) {
            if isExpanded != expanded { isExpanded = expanded }
            drag = SheetDrag()
        }
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
