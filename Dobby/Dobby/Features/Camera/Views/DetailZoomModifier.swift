// Created by mason on 10/22/26.
import SwiftUI
/// 프리뷰에서 핀치하고 같은 위치의 단일 버튼으로 배율을 왕복 선택한다.
struct DetailZoomModifier: ViewModifier {
    let options: DetailCameraOptions?
    let enabled: Bool
    @State private var stops = DetailZoomStops()
    @State private var pinchStart: Double?
    @GestureState private var pinching = false
    private var value: Double { options?.appliedZoom ?? 1 }
    private var label: String { String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "") + "x" }
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(MagnifyGesture()
                .updating($pinching) { _, active, _ in active = true }
                .onChanged { gesture in
                    guard enabled, let options, options.appliedZoom != nil else { return }
                    if pinchStart == nil { pinchStart = value; stops = DetailZoomStops() }
                    options.requestZoom((pinchStart ?? value) * gesture.magnification)
                })
            .onChange(of: pinching) { _, active in if !active { pinchStart = nil } }
            .onChange(of: enabled) { _, active in if !active { pinchStart = nil } }
            .overlay(alignment: .bottom) {
                if enabled, let options, let range = options.capabilities.zoom, options.appliedZoom != nil {
                    VStack(spacing: 4) {
                        if options.failure != nil, case .zoom = options.requested {
                            Text("줌을 적용하지 못했어요. 다시 시도해 주세요.").font(.caption)
                        }
                        Button {
                            options.requestZoom(stops.next(from: value, range: range))
                        } label: {
                            Text(label).font(.footnote.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(label == "1x" ? .white : .yellow)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain).disabled(options.isApplying || pinching)
                        .accessibilityLabel("카메라 줌").accessibilityValue(label)
                        .accessibilityHint("탭하여 배율을 변경하거나 미리보기를 두 손가락으로 확대하세요.")
                        .accessibilityIdentifier("camera.zoom")
                    }
                    .padding(.bottom, 156)
                }
            }
    }
}
