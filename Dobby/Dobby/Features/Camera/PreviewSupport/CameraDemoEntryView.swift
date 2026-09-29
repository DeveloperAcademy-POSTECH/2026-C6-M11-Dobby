//
//  CameraDemoEntryView.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import SwiftUI

/// Isolated review entry. Does not change the app's existing root or request camera access.
struct CameraDemoEntryView: View {
    @State private var isPresented = false

    var body: some View {
        VStack(spacing: 20) {
            Text("카메라 목 데모")
                .font(.title2.bold())
            Text("실제 촬영이나 측정을 수행하지 않습니다.")
                .foregroundStyle(.secondary)
            Button("카메라 흐름 살펴보기") { isPresented = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .fullScreenCover(isPresented: $isPresented) {
            CameraFlowView(model: CameraModel(
                captureProvider: MockCameraService(), processor: MockCaptureProcessor()
            ))
        }
    }
}

#Preview("카메라 독립 진입") {
    CameraDemoEntryView()
}
