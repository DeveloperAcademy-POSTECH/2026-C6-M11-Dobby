//
//  HomePreview.swift
//  Dobby
//
//  Created by mason on 10/5/26.
//

import SwiftUI

#if DEBUG
#Preview("홈 · 촬영 버튼 확인") {
    HomePreview()
}

#Preview("홈 · 큰 글씨") {
    HomePreview().environment(\.dynamicTypeSize, .accessibility3)
}

private struct HomePreview: View {
    @State private var showCaptureConfirmation = false

    var body: some View {
        // 독립 Preview에서는 실제 촬영 화면 대신 확인 알림을 표시합니다.
        TabView {
            Tab("홈", systemImage: "house.fill") {
                HomeView { showCaptureConfirmation = true }
            }
            Tab("보관함", systemImage: "hanger") {
                ContentUnavailableView("보관함 미리보기", systemImage: "hanger")
            }
        }
        .tint(.primary)
        .preferredColorScheme(.light)
        .alert("촬영 시작 버튼 확인", isPresented: $showCaptureConfirmation) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("실제 앱에서는 제품 촬영 화면으로 이동합니다.")
        }
    }
}
#endif
