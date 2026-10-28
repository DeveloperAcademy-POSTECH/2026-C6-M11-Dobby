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

#Preview("홈 · 이어하기") {
    HomePreview(showsDraft: true)
}

#Preview("홈 · 이어하기 · 좁은 화면과 큰 글씨") {
    HomePreview(showsDraft: true)
        .environment(\.dynamicTypeSize, .accessibility3)
        .frame(width: 320)
}

private struct HomePreview: View {
    var showsDraft = false
    @State private var showCaptureConfirmation = false
    @State private var showResumeConfirmation = false
    // 표시 전용 데이터입니다. SwiftData나 사진 파일에 저장하지 않습니다.
    private let candidate = HomeResumeCandidate(
        garment: Garment(category: "Jacket", group: .top),
        draft: ProductCreationDraft(step: .details, measurementRecordID: UUID(),
            photoState: nil, measurementInputData: nil,
            savedAt: .now.addingTimeInterval(-3 * 24 * 60 * 60)))

    var body: some View {
        // 독립 Preview에서는 실제 촬영 화면 대신 확인 알림을 표시합니다.
        TabView {
            Tab("홈", systemImage: "house.fill") {
                HomeView(resumeCandidate: showsDraft ? candidate : nil,
                    onResumeDraft: { _ in showResumeConfirmation = true },
                    onStartCapture: { showCaptureConfirmation = true })
            }
            Tab("보관함", systemImage: "hanger") {
                ContentUnavailableView("보관함 미리보기", systemImage: "hanger")
            }
            Tab("설정", systemImage: "gearshape.fill") {
                NavigationStack { SettingsView() }
            }
        }
        .tint(.primary)
        .preferredColorScheme(.light)
        .alert("촬영 시작 버튼 확인", isPresented: $showCaptureConfirmation) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("실제 앱에서는 제품 촬영 화면으로 이동합니다.")
        }
        .alert("이어하기 버튼 확인", isPresented: $showResumeConfirmation) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("표시용 미리보기입니다. 실제 앱에서는 저장한 작업을 이어서 진행합니다.")
        }
    }
}
#endif
