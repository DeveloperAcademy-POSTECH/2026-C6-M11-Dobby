//
//  DetailCaptureGuideView.swift
//  Dobby
//
//  Created by mason on 10/20/26.
//

import SwiftUI

/// 첫 터치는 안내만 닫는다. 모달이 하위 셔터와 내비게이션으로의 터치 전달을 막는다.
struct DetailCaptureGuideView: View {
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            ZStack {
                Color.black.opacity(0.57)
                VStack(spacing: 24) {
                    Image("DetailCaptureTapGuide")
                        .resizable().frame(width: 76, height: 111)
                        .accessibilityHidden(true)
                    VStack(spacing: 0) {
                        Text("이제 제품의 디테일들을 촬영해요")
                            .font(.callout.bold()).frame(minHeight: 26)
                        Text("화면을 터치해서 시작해주세요!")
                            .font(.subheadline.weight(.medium)).frame(minHeight: 26)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 4)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ignoresSafeArea()
        .accessibilityLabel("이제 제품의 디테일들을 촬영해요")
        .accessibilityHint("이중 탭하면 안내를 닫고 촬영을 시작할 수 있어요.")
        .accessibilityIdentifier("camera.startDetailCapture")
        .accessibilityAction(.escape, onStart)
    }
}
