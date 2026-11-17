import SwiftUI

/// Native home artwork and the prototype's downward-only pull interaction.
/// The parent owns capture navigation; this view owns only the home gesture.
struct HomeTapeMeasure: View {
    static let referenceSize = CGSize(width: 402, height: 553.82)
    let onStartCapture: () -> Void
    var onPrepareMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onMeasurementTransitionChanged: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onCancelMeasurementTransition: (() -> Void)? = nil
    var onBeginMeasurementTransition: ((HomeMeasurementTransitionSeed) -> Void)? = nil
    var onPullChanged: ((CGFloat) -> Void)? = nil
    var canvasSize: CGSize? = nil
    var measurementHaptics: HomeMeasurementHaptics? = nil
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var gestureActive = false
    @State private var pull: CGFloat = 0
    @State private var tapeLead: CGFloat = 0
    @State private var interactionCanvasSize: CGSize?
    @State private var interactionArtworkWidth: CGFloat?
    @State private var phase = Phase.idle
    @State private var idleStart = Date.now
    @State private var operationID = UUID()
    @State private var animationTask: Task<Void, Never>?

    private enum Phase { case idle, dragging, returning, accessiblePull, committed }

    var body: some View {
        GeometryReader { geometry in
            let scale = max(0, geometry.size.width / Self.referenceSize.width)
            let artworkWidth = geometry.size.width
            let size = canvasSize ?? CGSize(width: artworkWidth, height: 874 * scale)
            let artworkSize = CGSize(width: artworkWidth, height: size.height)
            let arrowTargetHeight = max(44, 64 * scale)
            let arrowTargetY = min(521 * scale, max(arrowTargetHeight / 2, geometry.size.height - arrowTargetHeight / 2))
            TimelineView(.animation(paused: reducedMotion || scenePhase != .active || phase != .idle)) { timeline in
                let cueEnabled = !reducedMotion && scenePhase == .active
                let displayedLead = phase == .idle
                    ? (cueEnabled ? HomeMeasurementMotion.idleTapeOffset(
                        elapsed: timeline.date.timeIntervalSince(idleStart)) : 0) : tapeLead
                let tape = HomeMeasurementMotion.pose(seed: .init(pull: pull, canvasSize: artworkSize,
                    tapeLead: displayedLead), progress: 0).tape
                ZStack(alignment: .topLeading) {
                    HomeMeasurementHomeArtwork(pull: pull, tapeLead: displayedLead, canvasSize: artworkSize)
                        .frame(width: artworkSize.width, height: artworkSize.height)
                    Image("HomeTransitionArrow")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 47 * scale, height: 36.8198 * scale)
                        .rotationEffect(.degrees(90))
                        .position(x: 201 * scale, y: 521 * scale)
                        .opacity(1 - HomeMeasurementMotion.smooth(Double(pull / 125)))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                    // Keep this target mounted when the decorative arrow fades,
                    // so an arrow-origin pull owns the same drag until release.
                    Color.clear
                        .frame(width: max(44, 72 * scale), height: arrowTargetHeight)
                        .contentShape(Rectangle())
                        .position(x: 201 * scale, y: arrowTargetY)
                        .highPriorityGesture(pullGesture(size: size, artworkWidth: artworkWidth, pickupLead: displayedLead))
                        .allowsHitTesting(phase == .idle || phase == .dragging)
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("화살표 당겨 실측 촬영 시작")
                        .accessibilityHint("화살표를 아래로 당기거나 이중 탭해 새 제품 실측을 시작합니다")
                        .accessibilityIdentifier("home.pullArrow")
                        .accessibilityAction(.default) {
                            startAccessibleCapture(size: size, artworkWidth: artworkWidth, pickupLead: displayedLead)
                        }
                    Color.clear
                        .frame(width: max(44, 104.52 * scale), height: max(44, 87.4 * scale))
                        .contentShape(Rectangle())
                        .position(tape.capCenter)
                        .highPriorityGesture(pullGesture(size: size, artworkWidth: artworkWidth, pickupLead: displayedLead))
                        .allowsHitTesting(phase == .idle || phase == .dragging)
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("줄자 당겨 실측 촬영 시작")
                        .accessibilityHint("줄자 끝을 아래로 당기거나 이중 탭해 새 제품 실측을 시작합니다")
                        .accessibilityIdentifier("product-flow.start")
                        .accessibilityAction(.default) {
                            startAccessibleCapture(size: size, artworkWidth: artworkWidth, pickupLead: displayedLead)
                        }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
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
        .onChange(of: reducedMotion) { _, _ in
            if phase == .idle { idleStart = .now }
        }
    }

    private func pullGesture(size: CGSize, artworkWidth: CGFloat, pickupLead: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard scenePhase == .active, phase == .idle || phase == .dragging else { return }
                if phase == .idle {
                    // Take the real window snapshot before changing any artwork,
                    // card opacity or cue position on the first touch update.
                    interactionCanvasSize = size
                    interactionArtworkWidth = artworkWidth
                    onPrepareMeasurementTransition?(.init(pull: 0, canvasSize: size,
                        artworkWidth: artworkWidth, tapeLead: pickupLead))
                    measurementHaptics?.startPull()
                    operationID = UUID()
                    // Hold the currently displayed cue under the finger. It is
                    // cosmetic extension, never a threshold or haptic distance.
                    tapeLead = pickupLead
                    phase = .dragging
                }
                let distance = HomeMeasurementMotion.normalizedPull(translation: value.translation.height,
                    canvasWidth: interactionArtworkWidth ?? artworkWidth)
                setPull(distance)
                measurementHaptics?.updatePull(distance)
            }
            .onEnded { _ in
                guard scenePhase == .active, phase == .dragging else { return }
                if HomeMeasurementMotion.shouldCommit(pull: pull) {
                    commit(size: size, artworkWidth: artworkWidth)
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
        if let size = interactionCanvasSize {
            onMeasurementTransitionChanged?(.init(pull: value, canvasSize: size,
                artworkWidth: interactionArtworkWidth, tapeLead: tapeLead))
        }
    }

    private func returnHome() {
        measurementHaptics?.stop()
        animationTask?.cancel()
        let token = UUID()
        operationID = token
        phase = .returning
        let duration = reducedMotion ? 0 : HomeMeasurementMotion.returnDuration
        withAnimation(duration == 0 ? nil : .timingCurve(1.0 / 3, 0, 2.0 / 3, 1, duration: duration)) {
            tapeLead = 0
            setPull(0)
        }
        animationTask = Task { @MainActor in
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled, operationID == token, phase == .returning else { return }
            idleStart = .now
            phase = .idle
            animationTask = nil
            interactionCanvasSize = nil
            interactionArtworkWidth = nil
            onCancelMeasurementTransition?()
        }
    }

    private func startAccessibleCapture(size: CGSize, artworkWidth: CGFloat, pickupLead: CGFloat) {
        guard phase == .idle, scenePhase == .active else { return }
        guard onBeginMeasurementTransition != nil else { onStartCapture(); return }
        interactionCanvasSize = size
        interactionArtworkWidth = artworkWidth
        onPrepareMeasurementTransition?(.init(pull: 0, canvasSize: size,
            artworkWidth: artworkWidth, tapeLead: pickupLead))
        measurementHaptics?.startPull()
        tapeLead = pickupLead
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
            commit(size: size, artworkWidth: artworkWidth)
        }
    }

    private func commit(size: CGSize, artworkWidth: CGFloat) {
        guard scenePhase == .active else { resetInteraction(); return }
        phase = .committed
        let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: interactionCanvasSize ?? size,
            artworkWidth: interactionArtworkWidth ?? artworkWidth, tapeLead: tapeLead)
        if let onBeginMeasurementTransition { onBeginMeasurementTransition(seed) }
        else { measurementHaptics?.finishPull(); onStartCapture() }
    }

    private func resetInteraction(stoppingHaptics: Bool = true) {
        let wasCommitted = phase == .committed
        if stoppingHaptics { measurementHaptics?.stop() }
        animationTask?.cancel()
        animationTask = nil
        operationID = UUID()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .idle
            pull = 0
            tapeLead = 0
            interactionCanvasSize = nil
            interactionArtworkWidth = nil
            onPullChanged?(0)
            idleStart = .now
        }
        if !wasCommitted { onCancelMeasurementTransition?() }
    }
}

/// Animating the input rather than the final pose preserves the prototype's
/// analytic strip/follow curves throughout the 250ms cancellation and 300ms pull.
private struct HomeMeasurementHomeArtwork: View, Animatable {
    var pull: CGFloat
    var tapeLead: CGFloat
    let canvasSize: CGSize
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pull, tapeLead) }
        set { pull = newValue.first; tapeLead = newValue.second }
    }

    var body: some View {
        let seed = HomeMeasurementTransitionSeed(pull: pull, canvasSize: canvasSize, tapeLead: tapeLead)
        let pose = HomeMeasurementMotion.pose(seed: seed, progress: 0)
        ZStack(alignment: .topLeading) {
            HomeMeasurementTapeArtwork(seed: seed, progress: 0)
            HomeMeasurementBody(pose: pose)
        }
        .transaction { $0.animation = nil }
    }
}
