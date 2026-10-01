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
    @State private var completed: ProductPhotoOutput?
    @State private var inputError: String?
    private let authorizer: any CameraAuthorizing

    init(authorizer: (any CameraAuthorizing)? = nil) {
        self.authorizer = authorizer ?? SystemCameraAuthorization()
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("상세 촬영·사진 선택 목 데모")
                .font(.title2.bold())
            Text("Figma의 샘플 사진으로 화면을 확인합니다. 권한은 실제로 확인하며 촬영은 목 데이터입니다.")
                .foregroundStyle(.secondary)
            Button("카메라 흐름 살펴보기", action: startDemo)
                .buttonStyle(.borderedProminent)
            if let completed {
                Text("완료 결과 수신: 선택 \(completed.selectedPhotos.count)장 / 상세 \(completed.detailPhotos.count)장")
            }
            if let inputError { Text(inputError).foregroundStyle(.red) }
        }
        .padding()
        .fullScreenCover(isPresented: $isPresented) {
            if let model {
                NavigationStack {
                    CameraFlowView(model: model, permission: CameraPermission(authorizer: authorizer),
                                   previewSource: (try? CameraPreviewPhotos.source(at: model.detailPhotos.count + 1)) ?? .mockPlaceholder) { output in
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
            model = try CameraPreviewPhotos.makeModel()
            completed = nil
            inputError = nil
            isPresented = true
        } catch {
            inputError = "샘플 사진을 불러오지 못했어요. 앱에 이미지가 포함되어 있는지 확인해 주세요."
        }
    }
}

#Preview("카메라 독립 진입") {
    CameraDemoEntryView(authorizer: MockCameraAuthorization())
}
