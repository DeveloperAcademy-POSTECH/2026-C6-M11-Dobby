//
//  CameraDemoEntryView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI

/// 이전 실측 화면을 목 입력으로 대체한다. 실제 앱 연결은 이 조립 지점에서 교체한다.
struct CameraDemoEntryView: View {
    @State private var isPresented = false
    @State private var model: ProductPhotoModel?
    @State private var camera: CameraPreviewSession?
    @State private var completed: ProductPhotoOutput?
    @State private var inputError: String?
    private let authorizer: any CameraAuthorizing
    private let usesSamplePreview: Bool

    init(authorizer: (any CameraAuthorizing)? = nil, usesSamplePreview: Bool = false) {
        self.authorizer = authorizer ?? SystemCameraAuthorization()
        self.usesSamplePreview = usesSamplePreview
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(usesSamplePreview ? "상세 촬영·전체 사진 전달 목 데모" : "상세 촬영 카메라 확인")
                .font(.title2.bold())
            Text(usesSamplePreview
                 ? "샘플 사진으로 화면을 확인합니다. 촬영은 목 데이터입니다."
                 : "실제 옷을 촬영하면 앱 내부에 저장하고 썸네일로 표시합니다. 실측 입력만 빈 자리로 대체합니다.")
                .foregroundStyle(.secondary)
            Button("카메라 흐름 살펴보기", action: startDemo)
                .buttonStyle(.borderedProminent)
            if let completed {
                Text("완료 결과 수신: 전체 \(completed.selectedPhotos.count)장 / 상세 \(completed.detailPhotos.count)장")
            }
            if let inputError { Text(inputError).foregroundStyle(.red) }
        }
        .padding()
        .fullScreenCover(isPresented: $isPresented) {
            if let model {
                NavigationStack {
                    CameraFlowView(model: model, permission: CameraPermission(authorizer: authorizer),
                                   camera: camera,
                                   previewSource: usesSamplePreview ? ((try? CameraPreviewPhotos.source(at: model.detailPhotos.count + 1)) ?? .mockPlaceholder) : nil) { output in
                        completed = output
                        isPresented = false
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("닫기", systemImage: "chevron.left") { isPresented = false }
                                .labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
    }

    private func startDemo() {
        do {
            if usesSamplePreview {
                camera = nil
                model = try CameraPreviewPhotos.makeModel()
            } else {
                // 실측 담당 화면을 대신하는 테스트 입력이다. 실측을 실행하거나 사진을 만들지 않는다.
                let measurement = CapturedAsset(id: UUID(), sessionID: UUID(), garmentID: UUID(),
                    purpose: .measurement, capturedAt: Date(), source: .mockPlaceholder)
                let session = CameraPreviewSession()
                model = try ProductPhotoModel(input: ProductPhotoInput(sessionID: measurement.sessionID,
                    garmentID: measurement.garmentID, measurement: measurement), captureProvider: session)
                camera = session
            }
            completed = nil
            inputError = nil
            isPresented = true
        } catch {
            inputError = "테스트 화면을 준비하지 못했어요. 입력 사진을 확인해 주세요."
        }
    }
}

#Preview("카메라 독립 진입") {
    CameraDemoEntryView(authorizer: MockCameraAuthorization(), usesSamplePreview: true)
}
