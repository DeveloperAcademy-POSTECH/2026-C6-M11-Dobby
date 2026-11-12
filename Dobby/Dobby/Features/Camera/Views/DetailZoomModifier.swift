// Created by mason on 10/22/26.
import SwiftUI
/// 프리뷰에서 핀치하고 같은 위치의 단일 버튼으로 배율을 왕복 선택한다.
struct DetailZoomModifier: ViewModifier {
    let options: DetailCameraOptions?
    let enabled: Bool
    var bottomSafeAreaInset: CGFloat = 0
    var minimumPhotoTop: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        if enabled, let options, let range = options.capabilities.zoom,
                           options.appliedZoom != nil, let chrome = zoomLayout(in: geometry.size) {
                            Button {
                                options.requestZoom(stops.next(from: value, range: range))
                            } label: {
                                Text(label).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(CameraZoomStyle.selectedText)
                                    .frame(width: 48, height: 48)
                                    .glassEffect(.regular.tint(.black.opacity(0.18)).interactive(), in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain).disabled(options.isApplying || pinching)
                            .position(x: chrome.zoomCenterX, y: chrome.zoomCenterY)
                            .accessibilityLabel("촬영 배율").accessibilityValue(label)
                            .accessibilityHint("탭하여 배율을 변경하거나 미리보기를 두 손가락으로 확대하세요.")
                            .accessibilityIdentifier("camera.zoom")
                            if options.failure != nil, case .zoom = options.requested {
                                Text("줌을 적용하지 못했어요. 다시 시도해 주세요.")
                                    .font(.caption).multilineTextAlignment(.center)
                                    .position(x: chrome.zoomCenterX, y: max(12, chrome.zoomFrame.y - 18))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.30),
                        value: options?.photoAspectRatio ?? .fourThree)
                    .animation(nil, value: geometry.size)
                }
            }
    }

    private func zoomLayout(in size: CGSize) -> MeasurementCameraChromeLayout? {
        let layout = DetailCameraPreviewLayout(containerSize: size,
            aspectRatio: options?.photoAspectRatio ?? .fourThree, prefersBottomAlignedPortrait: true,
            minimumPhotoTop: minimumPhotoTop)
        let rect = layout.photoFrame
        let photo = CameraPhotoViewport(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        guard let controls = layout.controls(in: size, bottomSafeAreaInset: bottomSafeAreaInset) else { return nil }
        return MeasurementCameraChromeLayout.layout(containerWidth: Double(size.width),
            containerHeight: Double(size.height), photo: photo, guidanceHeight: 0, shutter: controls.shutter)
    }
}
