//
//  HomeView.swift
//  Dobby
//
//  Created by mason on 10/5/26.
//

import SwiftUI

/// 홈 콘텐츠만 담당합니다. 탭·촬영 화면 전환은 부모가 소유합니다.
struct HomeView: View {
    let onStartCapture: () -> Void
    @ScaledMetric(relativeTo: .title3) private var guidanceLineHeight = 29

    var body: some View {
        GeometryReader { geometry in
            let reference = HomeTapeMeasure.referenceSize
            // 기준 화면에서 안내문 y=610. 짧은 화면·큰 글씨에서는 그림만 균일 축소합니다.
            let availableHeight = max(0, geometry.size.height - guidanceLineHeight * 2 - 24)
            let scale = max(0.35, min(1, geometry.size.width / reference.width, availableHeight / 610))
            ScrollView(.vertical) {
                VStack(spacing: 56.18 * scale) {
                    HomeTapeMeasure(onStartCapture: onStartCapture)
                        .frame(width: reference.width * scale, height: reference.height * scale)
                    VStack(spacing: 0) {
                        Text("줄자 버튼을 눌러서").frame(minHeight: guidanceLineHeight)
                        Text("실측 시작하기").frame(minHeight: guidanceLineHeight)
                    }
                    .font(HomeTypography.guidance)
                    .tracking(-0.2)
                    .foregroundStyle(Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.guidance")
                    .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color("HomeBackground").ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}
