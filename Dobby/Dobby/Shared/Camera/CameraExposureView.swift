// Created by mason on 10/22/26.
import SwiftUI

/// 사진 확인·셔터 영역을 대신하는 노출 패널. UI 상태는 View, 실제 적용값은 Model이 소유한다.
struct CameraExposureView: View {
    let state: CameraOptionsState
    let onChangeExposure: (Double) -> Void
    let onBack: () -> Void
    @State private var value = 0.0
    @State private var dragStart: Double?
    private var valueText: String { String(format: value > 0 ? "+%.1f" : "%.1f", value == 0 ? 0 : value) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text("노출").font(.caption)
                HStack {
                    Button("더보기로 돌아가기", systemImage: "chevron.left", action: onBack)
                        .accessibilityIdentifier("camera.exposureBack")
                    Spacer()
                    if abs(value) > 0.01 {
                        Button("노출 초기화", systemImage: "arrow.counterclockwise") { change(0) }
                            .disabled(state.exposureRange == nil)
                            .accessibilityIdentifier("camera.exposureReset")
                    }
                }
                .labelStyle(.iconOnly).buttonStyle(.bordered).tint(.primary)
                .buttonBorderShape(.circle).controlSize(.large)
            }
            Text(state.appliedExposure == nil ? "—" : valueText)
                .font(.largeTitle).monospacedDigit()
                .accessibilityIdentifier("camera.exposureValue")
            if let range = state.exposureRange, range.lowerBound < range.upperBound {
                ruler(range: range)
            } else {
                Text("카메라가 준비되면 조절할 수 있어요.").font(.footnote)
            }
            if state.hasExposureFailure {
                Text("노출을 적용하지 못했어요. 다시 조절해 주세요.").font(.footnote)
                    .accessibilityIdentifier("camera.exposureError")
            }
        }
        .padding(16).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, 8).padding(.bottom, 24)
        .accessibilityIdentifier("camera.exposurePanel")
        .accessibilityAction(.escape, onBack)
        .onAppear { value = state.appliedExposure ?? 0 }
        .onChange(of: state.appliedExposure) { _, applied in
            if !state.isApplying { value = applied ?? 0 }
        }
        .onChange(of: state.isApplying) { _, busy in
            if !busy { value = state.appliedExposure ?? 0 }
        }
    }

    private func ruler(range: ClosedRange<Double>) -> some View {
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
            context.fill(Path(CGRect(x: size.width / 2, y: 8, width: 2, height: 28)), with: .color(.yellow))
        }
        .frame(height: 44).clipped().contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStart == nil { dragStart = value }
                change((dragStart ?? value) - gesture.translation.width / 120)
            }
            .onEnded { _ in dragStart = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("노출 조절").accessibilityValue("\(valueText) EV")
        .accessibilityAdjustableAction { direction in
            change(value + (direction == .increment ? 0.1 : -0.1))
        }
        .accessibilityIdentifier("camera.exposureRuler")
    }

    private func change(_ proposed: Double) {
        guard proposed.isFinite, let range = state.exposureRange,
              range.lowerBound.isFinite, range.upperBound.isFinite else { return }
        let limited = min(max((proposed * 10).rounded() / 10, range.lowerBound), range.upperBound)
        guard limited != value || state.hasExposureFailure else { return }
        value = limited
        onChangeExposure(limited)
    }
}

