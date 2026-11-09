//
//  DetailCapturePreview.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import SwiftUI
import AVFoundation

#if DEBUG
/// Canvas에서 상위 화면 → 상세 촬영 → 전체 사진 전달을 직접 확인하는 목 진입점.
struct DetailCapturePreview: View {
    var photoCount = 3
    var authorization: AVAuthorizationStatus = .authorized
    @State private var model: ProductPhotoModel?
    @State private var path: [Bool] = []
    @State private var message = "실측 결과 자리"

    var body: some View {
        Group {
            if let model {
                NavigationStack(path: $path) {
                    Text(message).navigationTitle("실측 결과")
                        .navigationDestination(for: Bool.self) { _ in
                            CameraFlowView(model: model,
                                permission: CameraPermission(authorizer: MockCameraAuthorization(status: authorization)),
                                previewSource: (try? CameraPreviewPhotos.source(at: model.detailPhotos.count + 1)) ?? .mockPlaceholder
                            ) { output in
                                message = "전체 촬영 결과 수신: \(output.selectedPhotos.count)장"
                                path.removeAll()
                            }
                        }
                }
            } else {
                Text(message)
            }
        }
        .task {
            guard model == nil else { return }
            do {
                let prepared = try CameraPreviewPhotos.makeModel()
                for _ in 0..<max(photoCount - 1, 0) { try await prepared.captureDetail() }
                model = prepared
                path = [true]
            } catch { message = "샘플 이미지 로딩 실패"; path.removeAll() }
        }
    }
}

#Preview("상세 촬영 · 사진 3장") { DetailCapturePreview() }
#Preview("상세 촬영 · 첫 진입") { DetailCapturePreview(photoCount: 1) }
#Preview("상세 촬영 · 권한 거부") { DetailCapturePreview(authorization: .denied) }
#endif
