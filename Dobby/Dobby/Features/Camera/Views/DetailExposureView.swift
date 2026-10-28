// Created by mason on 10/22/26.
import SwiftUI

/// 사진 확인·셔터 영역을 대신하는 노출 패널. UI 상태는 View, 실제 적용값은 Model이 소유한다.
struct DetailExposureView: View {
    let options: DetailCameraOptions
    let presentation: DetailCaptureOptionsPresentation
    let onBack: () -> Void
    @State private var value = 0.0
    @State private var dragStart: Double?
    @State private var selectionFeedback = 0
    @GestureState private var isDragging = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let forceReduceMotion: Bool
    private var valueText: String { String(format: value > 0 ? "+%.1f" : "%.1f", value == 0 ? 0 : value) }

    init(options: DetailCameraOptions, presentation: DetailCaptureOptionsPresentation = .standard,
         forceReduceMotion: Bool = false,
         onBack: @escaping () -> Void) {
        self.options = options
        self.presentation = presentation
        self.forceReduceMotion = forceReduceMotion
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            Text(options.appliedExposure == nil ? "—" : valueText)
                .font(presentation == .measurement ? .title2 : .largeTitle).monospacedDigit()
                .accessibilityIdentifier("camera.exposureValue")
            if let range = options.capabilities.exposure, range.minimum < range.maximum {
                ruler(range: range)
            } else {
                Text("카메라가 준비되면 조절할 수 있어요.").font(.footnote)
            }
            if options.failure != nil {
                Text("노출을 적용하지 못했어요. 다시 조절해 주세요.").font(.footnote)
                    .accessibilityIdentifier("camera.exposureError")
            }
        }
        .padding(presentation == .measurement ? 12 : 16)
        .padding(.bottom, presentation == .measurement ? 8 : 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, 8).padding(.bottom, presentation == .measurement ? 16 : 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.exposurePanel")
        .accessibilityAction(.escape, onBack)
        // User input owns feedback; late hardware receipts and an initial
        // value restored when this panel opens must never vibrate the phone.
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .onAppear { value = options.appliedExposure ?? 0 }
        .onChange(of: options.appliedExposure) { _, applied in
            if dragStart == nil, !options.isApplying { value = applied ?? 0 }
        }
        .onChange(of: options.isApplying) { _, busy in
            if dragStart == nil, !busy { value = options.appliedExposure ?? 0 }
        }
        .onChange(of: isDragging) { _, active in
            // Rotation or interruption can cancel a touch without onEnded.
            if !active { finishDrag() }
        }
        .onDisappear { dragStart = nil }
    }

    private var header: some View {
        Group {
            if presentation == .measurement && dynamicTypeSize.isAccessibilitySize {
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
                .accessibilityIdentifier("camera.exposureBack")
            Spacer()
            if abs(value) > 0.01 {
                Button("노출 초기화", systemImage: "arrow.counterclockwise") { change(0, generatesFeedback: false) }
                    .disabled(options.capabilities.exposure == nil)
                    .accessibilityIdentifier("camera.exposureReset")
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered).tint(.primary)
        .buttonBorderShape(.circle).controlSize(.large)
    }

    private func ruler(range: DetailCameraControlRange) -> some View {
        ZStack {
            Canvas { context, size in
                // 지원 범위 안의 눈금만 이동시키고 중앙의 노란 지시선은 고정한다.
                for tick in -20...20 {
                    let index = Int((value * 10).rounded()) + tick
                    guard (range.minimum...range.maximum).contains(Double(index) / 10) else { continue }
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
        if !options.isApplying { value = options.appliedExposure ?? 0 }
    }

    private func change(_ proposed: Double, generatesFeedback: Bool = true) {
        guard let limited = options.capabilities.exposure?.clamped((proposed * 10).rounded() / 10),
              limited != value || options.failure != nil else { return }
        if presentation == .measurement, generatesFeedback,
           DetailExposureSelectionFeedback.hasChangedDisplayedStep(from: value, to: limited) {
            selectionFeedback &+= 1
        }
        value = limited
        options.requestExposure(limited)
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

#if DEBUG
#Preview("노출 조절 · 목 제어기") {
    @Previewable @State var options = DetailCameraOptions(controller: ExposurePreviewControls())
    DetailExposureView(options: options, onBack: {})
        .preferredColorScheme(.dark).background(Color.gray)
        .task { await options.refreshCapabilities() }
}
private actor ExposurePreviewControls: DetailCameraControlling {
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -2, maximum: 2), exposureBias: 0)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        guard case .exposure(let bias) = request else { throw DetailCameraControlFailure.unsupported }
        return bias
    }
}
#endif
