import SwiftUI

/// Native home artwork and the prototype's downward-only pull interaction.
/// The parent owns capture navigation; this view owns only the home gesture.
struct HomeTapeMeasure: View {
    static let referenceSize = CGSize(width: 402, height: 553.82)
    let onStartCapture: () -> Void
    var onPrepareMeasurementTransition: (() -> Void)? = nil
    var onBeginMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onPullChanged: ((CGFloat) -> Void)? = nil
    var showsResumeCard = false
    var canvasSize: CGSize? = nil
    var measurementHaptics: HomeMeasurementHaptics? = nil
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var gestureActive = false
    @State private var pull: CGFloat = 0
    @State private var phase = Phase.idle
    @State private var idleStart = Date.now
    @State private var operationID = UUID()
    @State private var animationTask: Task<Void, Never>?

    private enum Phase { case idle, dragging, returning, accessiblePull, committed }

    var body: some View {
        GeometryReader { geometry in
            let scale = max(0, geometry.size.width / Self.referenceSize.width)
            let size = canvasSize ?? CGSize(width: geometry.size.width, height: 874 * scale)
            ZStack(alignment: .topLeading) {
                HomeMeasurementHomeArtwork(pull: pull, canvasSize: size)
                    .frame(width: size.width, height: size.height)
                TimelineView(.animation(paused: reducedMotion || scenePhase != .active || phase != .idle)) { timeline in
                    let offset = phase == .idle
                        ? HomeMeasurementMotion.idleArrowOffset(elapsed: timeline.date.timeIntervalSince(idleStart),
                            reducedMotion: reducedMotion) : 0
                    HomeMeasurementArrowArtwork(pull: pull, offset: offset, scale: scale,
                        showsResumeCard: showsResumeCard)
                }
                Color.clear
                    .frame(width: max(44, 104.52 * scale), height: max(44, 87.4 * scale))
                    .contentShape(Rectangle())
                    .position(x: 201 * scale, y: 445.74 * scale)
                    .highPriorityGesture(pullGesture(size: size))
                    .allowsHitTesting(phase == .idle || phase == .dragging)
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("줄자 당겨 실측 촬영 시작")
                    .accessibilityHint("줄자 끝을 아래로 당기거나 이중 탭해 새 제품 실측을 시작합니다")
                    .accessibilityIdentifier("product-flow.start")
                    .accessibilityAction(.default) { startAccessibleCapture(size: size) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: gestureActive) { _, active in
                guard !active, phase == .dragging else { return }
                let token = operationID
                // GestureState resets as a gesture ends too. Let onEnded decide
                // commit/cancel before treating a missing onEnded as interruption.
                Task { @MainActor in
                    await Task.yield()
                    guard operationID == token, phase == .dragging, !gestureActive else { return }
                    returnHome()
                }
            }
        }
        .onAppear { idleStart = .now }
        .onDisappear {
            // ContentView retains the short rolling tail across this cover.
            resetInteraction(stoppingHaptics: phase != .committed)
        }
        .onChange(of: scenePhase) { _, value in
            if value != .active { resetInteraction() }
            else { idleStart = .now }
        }
    }

    private func pullGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard scenePhase == .active, phase == .idle || phase == .dragging else { return }
                if phase == .idle {
                    // Take the real window snapshot before changing any artwork,
                    // card opacity or arrow phase on the first touch update.
                    onPrepareMeasurementTransition?()
                    measurementHaptics?.startPull()
                    operationID = UUID()
                    phase = .dragging
                }
                let distance = HomeMeasurementMotion.normalizedPull(translation: value.translation.height,
                    canvasWidth: size.width)
                setPull(distance)
                measurementHaptics?.updatePull(distance)
            }
            .onEnded { _ in
                guard scenePhase == .active, phase == .dragging else { return }
                if HomeMeasurementMotion.shouldCommit(pull: pull) {
                    commit(size: size)
                } else if onBeginMeasurementTransition == nil && pull == 0 {
                    // Preserve the old standalone preview/API action. Production
                    // supplies the transition callback and ordinary taps cancel.
                    phase = .idle
                    onStartCapture()
                } else {
                    returnHome()
                }
            }
    }

    private func setPull(_ value: CGFloat) {
        pull = value
        onPullChanged?(value)
    }

    private func returnHome() {
        measurementHaptics?.stop()
        animationTask?.cancel()
        let token = UUID()
        operationID = token
        phase = .returning
        let duration = reducedMotion ? 0 : HomeMeasurementMotion.returnDuration
        withAnimation(duration == 0 ? nil : .timingCurve(1.0 / 3, 0, 2.0 / 3, 1, duration: duration)) {
            setPull(0)
        }
        animationTask = Task { @MainActor in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled, operationID == token, phase == .returning else { return }
            phase = .idle
            animationTask = nil
        }
    }

    private func startAccessibleCapture(size: CGSize) {
        guard phase == .idle, scenePhase == .active else { return }
        guard onBeginMeasurementTransition != nil else { onStartCapture(); return }
        onPrepareMeasurementTransition?()
        measurementHaptics?.startPull()
        phase = .accessiblePull
        let token = UUID()
        operationID = token
        let duration = reducedMotion ? 0 : HomeMeasurementMotion.accessiblePullDuration
        withAnimation(duration == 0 ? nil : .timingCurve(1.0 / 3, 0, 2.0 / 3, 1, duration: duration)) {
            setPull(HomeMeasurementMotion.accessiblePullDistance)
        }
        animationTask = Task { @MainActor in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled, operationID == token, phase == .accessiblePull else { return }
            animationTask = nil
            commit(size: size)
        }
    }

    private func commit(size: CGSize) {
        guard scenePhase == .active else { resetInteraction(); return }
        phase = .committed
        let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: size)
        if let onBeginMeasurementTransition { onBeginMeasurementTransition(seed) }
        else { measurementHaptics?.finishPull(); onStartCapture() }
    }

    private func resetInteraction(stoppingHaptics: Bool = true) {
        if stoppingHaptics { measurementHaptics?.stop() }
        animationTask?.cancel()
        animationTask = nil
        operationID = UUID()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .idle
            pull = 0
            onPullChanged?(0)
            idleStart = .now
        }
    }
}

/// Animating the input rather than the final pose preserves the prototype's
/// analytic strip/follow curves throughout the 250ms cancellation and 300ms pull.
private struct HomeMeasurementHomeArtwork: View, Animatable {
    var pull: CGFloat
    let canvasSize: CGSize
    var animatableData: CGFloat {
        get { pull }
        set { pull = newValue }
    }

    var body: some View {
        let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: canvasSize)
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: 0)
        ZStack(alignment: .topLeading) {
            HomeMeasurementTapeArtwork(seed: seed, progress: 0)
            HomeMeasurementBody(pose: pose)
        }
        .transaction { $0.animation = nil }
    }
}

private struct HomeMeasurementArrowArtwork: View, Animatable {
    var pull: CGFloat
    let offset: CGFloat
    let scale: CGFloat
    let showsResumeCard: Bool

    var animatableData: CGFloat {
        get { pull }
        set { pull = newValue }
    }

    var body: some View {
        Image("HomeTransitionArrow")
            .resizable()
            .scaledToFit()
            .frame(width: 37 * scale, height: 47 * scale)
            .position(x: 201 * scale, y: ((showsResumeCard ? 521 : 524) + offset) * scale)
            .opacity(1 - HomeMeasurementMotion.smooth(Double(pull / 125)))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
    }
}
