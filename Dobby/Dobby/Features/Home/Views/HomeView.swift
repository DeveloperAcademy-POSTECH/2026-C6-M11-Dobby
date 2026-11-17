import SwiftUI

/// Home keeps its native guidance/card; the parent owns capture navigation.
struct HomeView: View {
    var resumeCandidate: HomeResumeCandidate? = nil
    var onResumeDraft: ((UUID) -> Void)? = nil
    let onStartCapture: () -> Void
    var onPrepareMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onMeasurementTransitionChanged: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onCancelMeasurementTransition: (() -> Void)? = nil
    var onBeginMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var measurementHaptics: HomeMeasurementHaptics? = nil
    @State private var measurementPull: CGFloat = 0
    @ScaledMetric(relativeTo: .subheadline) private var guidanceLineHeight = HomeTypography.guidanceLineHeight
    @ScaledMetric(relativeTo: .subheadline) private var guidanceTracking = HomeTypography.guidanceTracking

    var body: some View {
        GeometryReader { geometry in
            let reference = HomeTapeMeasure.referenceSize
            // At the reference size, guidance starts at y576. On shorter layouts
            // the tape fits the space left by the guidance and optional draft card.
            let guidanceTop: CGFloat = 576
            let scale = max(0, geometry.size.width / reference.width)
            VStack(spacing: 0) {
                HomeTapeMeasure(onStartCapture: onStartCapture,
                    onPrepareMeasurementTransition: onPrepareMeasurementTransition,
                    onMeasurementTransitionChanged: onMeasurementTransitionChanged,
                    onCancelMeasurementTransition: onCancelMeasurementTransition,
                    onBeginMeasurementTransition: onBeginMeasurementTransition,
                    onPullChanged: { measurementPull = $0 },
                    canvasSize: CGSize(width: geometry.size.width,
                        height: max(geometry.frame(in: .global).maxY, geometry.size.height)),
                    measurementHaptics: measurementHaptics)
                    .aspectRatio(reference, contentMode: .fit)
                    .zIndex(1)
                HomeMeasurementLowerContent(pull: measurementPull) {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Text("줄자를 아래로 당겨").frame(minHeight: guidanceLineHeight)
                            Text("실측을 시작하세요").frame(minHeight: guidanceLineHeight)
                        }
                        .font(HomeTypography.guidance)
                        .tracking(guidanceTracking)
                        .foregroundStyle(Color("BrandNeutral500"))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("home.guidance")
                        .padding(.horizontal, 20)
                        .padding(.top, (guidanceTop - reference.height) * scale)
                        if let candidate = resumeCandidate, let onResumeDraft {
                            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                HomeResumeCard(step: candidate.draft.step, savedAt: candidate.draft.savedAt,
                                    referenceDate: timeline.date, productName: candidate.garment.name,
                                    onResume: { onResumeDraft(candidate.garment.id) }) {
                                    if let photo = candidate.garment.thumbnail {
                                        StoredProductPhotoView(photo: photo, maximumPixelSize: 500)
                                    } else {
                                        Color(white: 217.0 / 255)
                                    }
                                }
                            }
                            .frame(maxWidth: 361)
                            .padding(.horizontal, 20)
                            .padding(.top, 27 * scale)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color("BrandNeutral50").ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }
}

/// Reuse the real native guidance/card; only its opacity changes while pulling.
private struct HomeMeasurementLowerContent<Content: View>: View, Animatable {
    var pull: CGFloat
    private let content: Content

    init(pull: CGFloat, @ViewBuilder content: () -> Content) {
        self.pull = pull
        self.content = content()
    }

    var animatableData: CGFloat {
        get { pull }
        set { pull = newValue }
    }

    var body: some View {
        content.opacity(1 - HomeMeasurementMotion.smooth(Double(pull / 125)))
            .allowsHitTesting(pull == 0)
            .transaction { $0.animation = nil }
    }
}
