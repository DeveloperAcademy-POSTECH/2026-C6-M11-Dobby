//
//  HomeTapeMeasure.swift
//  Dobby
//
//  Created by mason on 10/5/26.
//

import SwiftUI

/// 402×440의 장식 영역. PNG에 포함된 그림자는 영역 밖으로 자연스럽게 이어집니다.
struct HomeTapeMeasure: View {
    let onStartCapture: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 402, geometry.size.height / 440)

            ZStack(alignment: .topLeading) {
                // 원본의 render bounds 기준. 투명 여백을 제외한 크기로 줄이면 비율이 달라집니다.
                decoration("HomeMeasuringTape", width: 249, height: 520, scale: scale)
                    .position(x: 197.5 * scale, y: 340 * scale)
                decoration("HomeTapeMeasureBody", width: 268, height: 315, scale: scale)
                    .position(x: 213 * scale, y: 151.5 * scale)

                Button(action: onStartCapture) {
                    Color.clear
                        .frame(width: max(44, 60 * scale), height: max(44, 60 * scale))
                        .contentShape(Circle())
                }
                .buttonStyle(HomeShutterPressStyle())
                .accessibilityLabel("옷 촬영 · 실측")
                .accessibilityHint("새 제품 촬영을 시작합니다")
                .accessibilityIdentifier("product-flow.start")
                .position(x: 200 * scale, y: 104 * scale)
            }
        }
    }

    private func decoration(_ name: String, width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: width * scale, height: height * scale)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct HomeShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color("HomeAccent").opacity(configuration.isPressed ? 0.25 : 0), in: Circle())
    }
}
