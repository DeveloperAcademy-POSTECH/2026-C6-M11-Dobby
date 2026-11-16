import SwiftUI

/// Home keeps its native guidance/card; the parent owns capture navigation.
struct HomeView: View {
    var resumeCandidate: HomeResumeCandidate? = nil
    var onResumeDraft: ((UUID) -> Void)? = nil
    let onStartCapture: () -> Void
    var onPrepareMeasurementTransition: (() -> Void)? = nil
    var onBeginMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    @State private var measurementPull: CGFloat = 0
    @ScaledMetric(relativeTo: .title3) private var guidanceLineHeight = 29

    private var showsResumeCard: Bool { resumeCandidate != nil && onResumeDraft != nil }

    var body: some View {
        GeometryReader { geometry in
            let reference = HomeTapeMeasure.referenceSize
            // Both supplied home variants start guidance at y574. The optional
            // native card follows the two 29pt lines and 20pt gap at y652.
            let guidanceTop: CGFloat = 574
            let scale = max(0, geometry.size.width / reference.width)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HomeTapeMeasure(onStartCapture: onStartCapture,
                        onPrepareMeasurementTransition: onPrepareMeasurementTransition,
                        onBeginMeasurementTransition: onBeginMeasurementTransition,
                        onPullChanged: { measurementPull = $0 }, showsResumeCard: showsResumeCard,
                        canvasSize: CGSize(width: geometry.size.width,
                            height: max(geometry.frame(in: .global).maxY, geometry.size.height)))
                        .frame(width: reference.width * scale, height: reference.height * scale)
                        .zIndex(1)
                    HomeMeasurementLowerContent(pull: measurementPull) {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                Text("줄자를 아래로 당겨").frame(minHeight: guidanceLineHeight)
                                Text("실측을 시작하세요").frame(minHeight: guidanceLineHeight)
                            }
                            .font(HomeTypography.guidance)
                            .tracking(-0.2)
                            .foregroundStyle(Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("home.guidance")
                            .padding(.horizontal, 20)
                            .padding(.top, (guidanceTop - reference.height) * scale)
                            if let candidate = resumeCandidate, let onResumeDraft {
                                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                    HomeResumeCard(step: candidate.draft.step, savedAt: candidate.draft.savedAt,
                                        referenceDate: timeline.date,
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
                                .padding(.top, 20)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color("BrandNeutral50").ignoresSafeArea())
        .preferredColorScheme(.light)
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
