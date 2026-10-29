// Created by mason on 10/30/26.
import SwiftUI

#Preview("AI 옵션 · ON", traits: .sizeThatFitsLayout) {
    ProductPhotoAIOptionPreview(initiallyOn: true).frame(width: 402)
}

#Preview("AI 옵션 · OFF", traits: .sizeThatFitsLayout) {
    ProductPhotoAIOptionPreview(initiallyOn: false).frame(width: 402)
}

#Preview("AI 옵션 · 좁은 화면 · 큰 글자", traits: .sizeThatFitsLayout) {
    ProductPhotoAIOptionPreview(initiallyOn: true)
        .frame(width: 320).dynamicTypeSize(.accessibility3)
}

#Preview("AI 옵션 · 조작 불가", traits: .sizeThatFitsLayout) {
    ProductPhotoAIOptionPreview(initiallyOn: true).disabled(true).frame(width: 402)
}

#Preview("제품 사진 선택 · AI 옵션 연결") {
    ProductPhotoAISelectionPreview()
}

private struct ProductPhotoAIOptionPreview: View {
    @State private var isOn: Bool

    init(initiallyOn: Bool) {
        _isOn = State(initialValue: initiallyOn)
    }

    var body: some View {
        ProductPhotoAIOptionRow(isOn: $isOn).preferredColorScheme(.light)
    }
}

private struct ProductPhotoAISelectionPreview: View {
    @State private var model: ProductPhotoModel?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            if let model {
                ProductPhotoSelectionView(model: model, onBack: {}) { output in
                    // Canvas에서만 저장 대기를 표현한다. 실제 저장·AI 요청은 수행하지 않는다.
                    try await Task.sleep(for: .seconds(2))
                    message = "미리보기: \(output.selectedPhotos.count)장 선택 결과 확인"
                }
            } else {
                ProgressView("미리보기 사진 준비 중")
            }
        }
        .alert("미리보기", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button("확인") { message = nil }
        } message: { Text(message ?? "") }
        .task {
            guard model == nil else { return }
            do {
                let preview = try CameraPreviewPhotos.makeModel()
                for _ in 0..<11 { try await preview.captureDetail() }
                model = preview
            } catch { message = "미리보기 사진을 불러오지 못했어요." }
        }
    }
}
