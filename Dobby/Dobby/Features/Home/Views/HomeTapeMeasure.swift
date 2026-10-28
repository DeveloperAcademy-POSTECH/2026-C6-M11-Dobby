//
//  HomeTapeMeasure.swift
//  Dobby
//
//  Created by mason on 10/5/26.
//

import SwiftUI

/// Figma의 줄자 영역(402×553.82). 화면 배치와 촬영 전환은 부모가 결정합니다.
struct HomeTapeMeasure: View {
    static let referenceSize = CGSize(width: 402, height: 553.82)
    let onStartCapture: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = max(0, min(geometry.size.width / Self.referenceSize.width,
                                   geometry.size.height / Self.referenceSize.height))
            let horizontalInset = (geometry.size.width - Self.referenceSize.width * scale) / 2

            ZStack(alignment: .topLeading) {
                // Figma 3594:9473의 화면 안 render bounds. 띠의 아래쪽은 본체 뒤에 겹칩니다.
                decoration("HomeTapeVertical", x: 170.134, width: 60.733, height: 258, scale: scale)
                decoration("HomeTapeMeasureBody", x: 45, y: 241, width: 312.82, height: 312.82, scale: scale)

                Button(action: onStartCapture) {
                    Color.clear
                        .frame(width: max(44, 81.42 * scale), height: max(44, 81.42 * scale))
                        .contentShape(Circle())
                }
                .buttonStyle(HomeShutterPressStyle())
                .accessibilityLabel("실측 촬영 시작")
                .accessibilityHint("새 제품 촬영을 시작합니다")
                .accessibilityIdentifier("product-flow.start")
                .position(x: 201.41 * scale, y: 397.41 * scale)
            }
            .frame(width: Self.referenceSize.width * scale, height: Self.referenceSize.height * scale)
            .offset(x: horizontalInset)
        }
    }

    private func decoration(_ name: String, x: CGFloat, y: CGFloat = 0,
                            width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: width * scale, height: height * scale)
            .position(x: (x + width / 2) * scale, y: (y + height / 2) * scale)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct HomeShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.black.opacity(configuration.isPressed ? 0.12 : 0), in: Circle())
    }
}
