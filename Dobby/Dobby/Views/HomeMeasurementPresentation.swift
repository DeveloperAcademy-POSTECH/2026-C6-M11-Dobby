import SwiftUI
import UIKit

/// The capture flow keeps one identity and one camera owner through the wipe.
/// Its live views become interactive when the decorative layers have departed.
struct HomeMeasurementPresentation<Content: View>: View {
    let seed: HomeMeasurementTransitionSeed?
    let snapshot: UIImage?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let seed {
            HomeMeasurementAnimatedPresentation(seed: seed, snapshot: snapshot, content: content)
        } else {
            content()
        }
    }
}

private struct HomeMeasurementAnimatedPresentation<Content: View>: View {
    let seed: HomeMeasurementTransitionSeed
    let snapshot: UIImage?
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress: Double = 0
    @State private var hasFinished = false

    var body: some View {
        HomeMeasurementTransitionOverlay(snapshot: snapshot, seed: seed, progress: progress) {
            content()
                .disabled(!hasFinished)
                .allowsHitTesting(hasFinished)
                .accessibilityHidden(!hasFinished)
        }
        .overlay {
            if !hasFinished {
                Color.clear
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("실측 화면 전환 중")
                    .accessibilityIdentifier("home.measurementTransition")
                    .allowsHitTesting(false)
            }
        }
        .interactiveDismissDisabled(!hasFinished)
        .task {
            guard !hasFinished else { return }
            if reduceMotion { finishWithoutMotion(); return }
            // Yield the first displayed frame so the cover starts at the exact
            // held position rather than appearing at the animation's end pose.
            await Task.yield()
            guard !Task.isCancelled, !hasFinished else { return }
            withAnimation(.linear(duration: HomeMeasurementMotion.transitionDuration)) { progress = 1 }
            do {
                try await Task.sleep(for: .seconds(HomeMeasurementMotion.transitionDuration))
                guard !Task.isCancelled else { return }
                hasFinished = true
            } catch { }
        }
        .onChange(of: scenePhase) { _, phase in
            // The camera already handles suspension. Never leave a frozen home
            // layer covering that camera after the app returns to foreground.
            if phase == .background { finishWithoutMotion() }
        }
        .onChange(of: reduceMotion) { _, enabled in
            if enabled { finishWithoutMotion() }
        }
    }

    private func finishWithoutMotion() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = 1; hasFinished = true }
    }
}

/// Weak window access has no published state and never captures another app.
@MainActor
final class HomeMeasurementSnapshotSource {
    weak var window: UIWindow?
    var canvasSize: CGSize? { window?.bounds.size }

    func snapshot() -> UIImage? {
        guard let window, window.bounds.width > 0, window.bounds.height > 0 else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

struct HomeMeasurementSnapshotAnchor: UIViewRepresentable {
    let source: HomeMeasurementSnapshotSource

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.source = source
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) { view.source = source; source.window = view.window }

    final class Anchor: UIView {
        weak var source: HomeMeasurementSnapshotSource?
        override func didMoveToWindow() { super.didMoveToWindow(); source?.window = window }
    }
}
