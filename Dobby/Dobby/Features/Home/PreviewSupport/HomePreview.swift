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
        // 실제 앱 연결 전 확인용 컨테이너입니다. 기존 ContentView의 경로는 변경하지 않습니다.
        TabView {
            Tab("홈", systemImage: "house") {
                HomeView { showCaptureConfirmation = true }
            }
            Tab("보관함", systemImage: "hanger") {
                ContentUnavailableView("보관함 미리보기", systemImage: "hanger")
            }
        }
        .tint(Color("HomeAccent"))
        .preferredColorScheme(.light)
        .alert("촬영 시작 버튼 확인", isPresented: $showCaptureConfirmation) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("실제 촬영 화면 연결은 3단계에서 진행합니다.")
        }
    }
}
#endif
