import SwiftUI
import UIKit

/// Confirms both endpoints on a draft before updating the current product's
/// measurement. Cancel never changes the original automatic observation.
struct GarmentTotalLengthCorrectionView: View {
    @State private var model: ManualMeasurement
    @State private var image: UIImage?
    @State private var activePointIndex = 0
    @State private var applyFailed = false
    @Environment(\.dismiss) private var dismiss
    let failure: MeasurementFailure?
    let onApply: (ManualMeasurement) -> Bool

    init(model: ManualMeasurement, initialImage: UIImage?, failure: MeasurementFailure?,
         onApply: @escaping (ManualMeasurement) -> Bool) {
        // Display previous positions, but require both points to be confirmed
        // in this draft even when the current result was already corrected.
        var pending = model.landmarks
        pending.origin = .model
        for index in pending.points.indices { pending.points[index].origin = .model }
        _model = State(initialValue: ManualMeasurement(snapshot: model.snapshot, landmarks: pending,
            definition: model.definition, options: model.options, testContext: model.testContext))
        _image = State(initialValue: initialImage)
        self.failure = failure
        self.onApply = onApply
    }

    private func isConfirmed(_ index: Int) -> Bool {
        guard model.displayLandmarks.points.indices.contains(index) else { return false }
        let point = model.displayLandmarks.points[index]
        return point.origin == .manual && point.isVisible && point.point.isValid && point.derivedFrom == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("사진에서 목 중앙과 밑단 중앙을 차례로 눌러 주세요.")
                        .font(.headline)
                    Text("같은 사진의 깊이로 총장을 다시 측정하고 현재 실측 결과에 반영해요. 깊이가 부족한 위치는 다시 촬영해야 해요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let failure {
                        Text(failure.message).font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                    }
                    HStack(spacing: 10) {
                        endpointButton(index: 0, title: "A · 목 중앙")
                        endpointButton(index: 1, title: "B · 밑단 중앙")
                    }
                    Text(activePointIndex == 0 ? "A · 목 중앙 위치를 눌러 주세요" : "B · 밑단 중앙 위치를 눌러 주세요")
                        .font(.caption.weight(.semibold))
                    MeasurementImageView(snapshot: model.snapshot, landmarks: model.displayLandmarks,
                        image: image, activePointIndex: activePointIndex, placePoint: placePoint)
                        .aspectRatio(SnapshotPresentation.aspectRatio(for: model.snapshot), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("totalLengthCorrectionPhoto")
                    Text("두 점을 모두 직접 지정해야 적용할 수 있어요. 지정한 점은 끌어서 조정할 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(GarmentCaptureStyle.background)
            .navigationTitle("총장 위치 지정").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }.accessibilityIdentifier("cancelTotalLengthCorrection")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if onApply(model) { dismiss() }
                    else { applyFailed = true }
                } label: {
                    Text("이 위치로 다시 측정").font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity).frame(minHeight: 56)
                        .background(GarmentCaptureStyle.accent, in: Capsule())
                        .contentShape(.interaction, Capsule())
                }.buttonStyle(.plain).foregroundStyle(.white)
                    .disabled(!isConfirmed(0) || !isConfirmed(1))
                    .opacity(isConfirmed(0) && isConfirmed(1) ? 1 : 0.45)
                    .accessibilityIdentifier("applyTotalLengthCorrection")
                    .padding(20).background(GarmentCaptureStyle.background)
            }
            .task {
                if image == nil, let decoded = await SnapshotPresentation.thumbnail(for: model.snapshot),
                   !Task.isCancelled { image = decoded }
            }
            .alert("위치를 적용하지 못했어요", isPresented: $applyFailed) {
                Button("확인", role: .cancel) { }
            } message: {
                Text("두 점을 다시 지정해 주세요. 촬영 사진이 바뀌었다면 실측 결과에서 다시 열어 주세요.")
            }
        }.tint(GarmentCaptureStyle.accent).preferredColorScheme(.dark)
    }

    private func endpointButton(index: Int, title: String) -> some View {
        Button { activePointIndex = index } label: {
            Label(title, systemImage: isConfirmed(index) ? "checkmark.circle.fill" : "plus.circle")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(minHeight: 44)
                .background(activePointIndex == index ? GarmentCaptureStyle.accent.opacity(0.18) : .white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityValue(isConfirmed(index) ? "위치 확인 완료" : "위치 확인 필요")
            .accessibilityIdentifier("totalLengthCorrectionEndpoint_\(index)")
    }

    private func placePoint(displayPoint: ImagePoint, index: Int) {
        guard model.placePoint(displayPoint: displayPoint, index: index) else { return }
        if !isConfirmed(0) { activePointIndex = 0 }
        else if !isConfirmed(1) { activePointIndex = 1 }
    }
}
