// Created by mason on 10/22/26.
import SwiftUI

/// 사진 확인·셔터 영역을 대신하는 노출 패널. UI 상태는 View, 실제 적용값은 Model이 소유한다.
struct CameraExposureView: View {
    let state: CameraOptionsState
    let onChangeExposure: (Double) -> Void
    let presentation: DetailCaptureOptionsPresentation
    private let embeddedInPanel: Bool
    let onBack: () -> Void
    @State private var value = 0.0
    @State private var dragStart: Double?
    @State private var selectionFeedback = 0
    @GestureState private var isDragging = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let forceReduceMotion: Bool
    /// Feedback can stay enabled independently of the chosen visual presentation.
    private let selectionFeedbackEnabled: Bool
    private var valueText: String { String(format: value > 0 ? "+%.1f" : "%.1f", value == 0 ? 0 : value) }

    init(state: CameraOptionsState, presentation: DetailCaptureOptionsPresentation = .standard,
         forceReduceMotion: Bool = false, selectionFeedbackEnabled: Bool? = nil,
         embeddedInPanel: Bool = false,
         onChangeExposure: @escaping (Double) -> Void,
         onBack: @escaping () -> Void) {
        self.state = state
        self.onChangeExposure = onChangeExposure
        self.presentation = presentation
        self.forceReduceMotion = forceReduceMotion
        self.selectionFeedbackEnabled = selectionFeedbackEnabled ?? (presentation == .measurement)
        self.embeddedInPanel = embeddedInPanel
        self.onBack = onBack
    }

    var body: some View {
        Group {
            if embeddedInPanel { controls }
            else {
                controls
                    .padding(presentation == .measurement ? 12 : 16)
                    .padding(.bottom, presentation == .measurement ? 8 : 12)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 40))
                    .padding(.horizontal, 8).padding(.bottom, presentation == .measurement ? 16 : 24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.exposurePanel")
        .accessibilityAction(.escape, onBack)
        // User input owns feedback; late hardware receipts and an initial
        // value restored when this panel opens must never vibrate the phone.
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .onAppear { value = state.appliedExposure ?? 0 }
        .onChange(of: state.appliedExposure) { _, applied in
            if dragStart == nil, !state.isApplying { value = applied ?? 0 }
        }
        .onChange(of: state.isApplying) { _, busy in
            if dragStart == nil, !busy { value = state.appliedExposure ?? 0 }
        }
        .onChange(of: isDragging) { _, active in
            // Rotation or interruption can cancel a touch without onEnded.
            if !active { finishDrag() }
        }
        .onDisappear { dragStart = nil }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            header
            Text(state.appliedExposure == nil ? "—" : valueText)
                .font(embeddedInPanel ? .system(.title, design: .rounded).weight(.light)
                    : presentation == .measurement ? .title2 : .largeTitle).monospacedDigit()
                .accessibilityIdentifier("camera.exposureValue")
            if let range = state.exposureRange, range.lowerBound < range.upperBound {
                ruler(range: range)
                    .frame(maxWidth: embeddedInPanel ? 200 : .infinity)
                    .frame(maxWidth: .infinity)
            } else {
                Text("카메라가 준비되면 조절할 수 있어요.").font(.footnote)
            }
            if state.hasExposureFailure {
                Text("노출을 적용하지 못했어요. 다시 조절해 주세요.").font(.footnote)
                    .accessibilityIdentifier("camera.exposureError")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        Group {
            if (embeddedInPanel || presentation == .measurement) && dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    headerButtons
                    Text("노출").font(.caption)
                }
            } else {
                ZStack {
                    Text("노출").font(.caption)
                    headerButtons
                }
            }
        }
    }

    private var headerButtons: some View {
        HStack {
            Button("더보기로 돌아가기", systemImage: "chevron.left", action: onBack)
                .labelStyle(.iconOnly).buttonStyle(.bordered).tint(.primary)
                .buttonBorderShape(.circle).controlSize(.large)
                .accessibilityIdentifier("camera.exposureBack")
            Spacer()
            if abs(value) > 0.01 {
                resetButton
            }
        }
    }

    private var resetButton: some View {
        Button { change(0, generatesFeedback: false) } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.2), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.exposureRange == nil)
        .accessibilityLabel("노출 초기화")
        .accessibilityIdentifier("camera.exposureReset")
    }

    private func ruler(range: ClosedRange<Double>) -> some View {
        ZStack {
            Canvas { context, size in
                // 지원 범위 안의 눈금만 이동시키고 중앙의 노란 지시선은 고정한다.
                for tick in -20...20 {
                    let index = Int((value * 10).rounded()) + tick
                    guard (range.lowerBound...range.upperBound).contains(Double(index) / 10) else { continue }
                    let x = size.width / 2 + (Double(index) / 10 - value) * 120
                    let height: CGFloat = index % 5 == 0 ? 16 : 10
                    context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: 1, height: height)),
                                 with: .color(.secondary))
                }
            }
            // Animate the indicator only. Eye-level feedback follows the finger
            // immediately without interpolating EV requests or camera receipts.
            Capsule().fill(.yellow)
                .frame(width: 2, height: presentation == .measurement ? (isDragging ? 36 : 16) : 28)
                .animation(presentation != .measurement || reduceMotion || forceReduceMotion ? nil
                    : .spring(response: 0.22, dampingFraction: 0.86), value: isDragging)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(height: 44).clipped().contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { gesture in
                if dragStart == nil { dragStart = value }
                change((dragStart ?? value) - gesture.translation.width / 120)
            }
            .onEnded { _ in finishDrag() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("노출 조절").accessibilityValue("\(valueText) EV")
        .accessibilityAdjustableAction { direction in
            change(value + (direction == .increment ? 0.1 : -0.1))
        }
        .accessibilityIdentifier("camera.exposureRuler")
    }

    private func finishDrag() {
        dragStart = nil
        if !state.isApplying { value = state.appliedExposure ?? 0 }
    }

    private func change(_ proposed: Double, generatesFeedback: Bool = true) {
        guard proposed.isFinite, let range = state.exposureRange,
              range.lowerBound.isFinite, range.upperBound.isFinite else { return }
        let limited = min(max((proposed * 10).rounded() / 10, range.lowerBound), range.upperBound)
        guard limited != value || state.hasExposureFailure else { return }
        if selectionFeedbackEnabled, generatesFeedback,
           DetailExposureSelectionFeedback.hasChangedDisplayedStep(from: value, to: limited) {
            selectionFeedback &+= 1
        }
        value = limited
        onChangeExposure(limited)
    }
}

/// Device EV receipts travel through Float. Their rounding noise must not
/// produce a selection tick when the same displayed tenth is touched again.
nonisolated enum DetailExposureSelectionFeedback {
    static func hasChangedDisplayedStep(from previous: Double, to next: Double) -> Bool {
        guard previous.isFinite, next.isFinite else { return false }
        return (previous * 10).rounded() != (next * 10).rounded()
    }
}
