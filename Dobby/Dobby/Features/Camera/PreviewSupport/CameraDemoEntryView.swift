//
//  CameraDemoEntryView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI

/// Reviews system permission and mock capture. Previews explicitly inject mock permission.
struct CameraDemoEntryView: View {
    @State private var isPresented = false
    private let authorizer: any CameraAuthorizing

    init(authorizer: (any CameraAuthorizing)? = nil) {
        self.authorizer = authorizer ?? SystemCameraAuthorization()
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("카메라 목 데모")
                .font(.title2.bold())
            Text("카메라 권한은 실제로 확인하며, 촬영과 측정은 목 데이터로 동작합니다.")
                .foregroundStyle(.secondary)
            Button("카메라 흐름 살펴보기") { isPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .fullScreenCover(isPresented: $isPresented) {
            CameraFlowView(model: CameraModel(
                captureProvider: MockCameraService(), processor: MockCaptureProcessor()
            ), permission: CameraPermission(authorizer: authorizer))
        }
    }
}

#Preview("카메라 독립 진입") {
    CameraDemoEntryView(authorizer: MockCameraAuthorization())
}
