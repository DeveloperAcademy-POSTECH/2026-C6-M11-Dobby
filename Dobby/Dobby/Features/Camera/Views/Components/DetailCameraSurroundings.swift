import SwiftUI

/// The bottom cover moves offscreen as the photograph reaches the bottom.
/// Only the header becomes translucent; controls remain separate foreground views.
struct DetailCameraSurroundings: View {
    let photoFrame: CGRect
    let topOpacity: Double

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.black.opacity(topOpacity)
                    .frame(width: size.width, height: max(0, photoFrame.minY))
                Color.black
                    .frame(width: size.width, height: max(0, size.height - photoFrame.maxY))
                    .offset(y: photoFrame.maxY)
                Color.black
                    .frame(width: max(0, photoFrame.minX), height: photoFrame.height)
                    .offset(y: photoFrame.minY)
                Color.black
                    .frame(width: max(0, size.width - photoFrame.maxX), height: photoFrame.height)
                    .offset(x: photoFrame.maxX, y: photoFrame.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
