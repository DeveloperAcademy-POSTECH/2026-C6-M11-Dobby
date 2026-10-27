// Created by mason on 10/27/26.
import SwiftUI

/// 상세 촬영 상·하단 띠. 영상은 비치게 두고 흰 컨트롤의 명도를 확보한다.
struct DetailCaptureGlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(white: 0.1)
            } else {
                Color.clear
                    .glassEffect(.clear, in: Rectangle())
                    .background(.black.opacity(0.2))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
