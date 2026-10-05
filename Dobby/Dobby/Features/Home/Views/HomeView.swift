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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("AllFit")
                .font(.title2.bold())
                .foregroundStyle(.black)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.title")
                .padding(.horizontal, 20)
                .padding(.top, 34)

            GeometryReader { geometry in
                // 작은 화면에서는 비율을 유지해 축소하고 넓은 화면에서는 과대 확대하지 않습니다.
                let scale = max(0, min(1, geometry.size.width / 402, geometry.size.height / 440))
                let artworkHeight = 440 * scale
                // Figma의 제목 아래 여백 : 그림 아래 여백 비율을 유지합니다.
                let topSpace = max(0, geometry.size.height - artworkHeight) * 0.43

                HomeTapeMeasure(onStartCapture: onStartCapture)
                    .frame(width: 402 * scale, height: artworkHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.top, topSpace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("HomeBackground").ignoresSafeArea())
    }
}
