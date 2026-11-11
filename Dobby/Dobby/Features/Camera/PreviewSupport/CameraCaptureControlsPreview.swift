// Created by mason on 11/10/26.
import SwiftUI

#if DEBUG
/// Component-only preview. The gallery placeholder never reads or saves photos.
private struct CameraCaptureControlsPreview: View {
    var width: CGFloat = 402
    var reduceMotion = false
    @State var isReady = true
    @State var isProcessing = false
    @State private var captureCount = 0
    @State private var showsOptions = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "photo")
                    .frame(width: 48, height: 48)
                    .background(.gray.opacity(0.3), in: Circle())
                    .accessibilityLabel("미리보기용 사진 자리")
                Spacer(minLength: 0)
                if isProcessing {
                    MeasurementProcessingIndicator(phase: .measuring,
                        forceReduceMotion: reduceMotion)
                } else {
                    CameraShutterControl(isEnabled: isReady, isCapturing: false,
                        action: { captureCount += 1 }, forceReduceMotion: reduceMotion)
                }
                Spacer(minLength: 0)
                CameraMoreButton(isEnabled: !isProcessing) { showsOptions.toggle() }
            }
            .padding(.horizontal, 48)
            .frame(height: 192)

            // Preview controls only; they do not drive a capture session.
            VStack(alignment: .leading, spacing: 12) {
                Toggle("촬영 가능", isOn: $isReady)
                Toggle("처리 중 표시", isOn: $isProcessing)
                Text("촬영 버튼 입력: \(captureCount)회")
                Text(showsOptions ? "더보기 입력 확인" : "더보기 닫힘")
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 24)
        .frame(width: width)
        .foregroundStyle(.white)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}

#Preview("촬영 버튼 · 활성", traits: .sizeThatFitsLayout) {
    CameraCaptureControlsPreview()
}
#Preview("촬영 버튼 · 비활성", traits: .sizeThatFitsLayout) {
    CameraCaptureControlsPreview(isReady: false)
}
#Preview("촬영 버튼 · 처리 중", traits: .sizeThatFitsLayout) {
    CameraCaptureControlsPreview(isProcessing: true)
}
#Preview("촬영 버튼 · 좁은 화면 / 동작 줄이기", traits: .sizeThatFitsLayout) {
    CameraCaptureControlsPreview(width: 320, reduceMotion: true)
}
#endif
