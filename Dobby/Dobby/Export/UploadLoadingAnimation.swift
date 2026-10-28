import Lottie
import SwiftUI

struct UploadLoadingAnimation: View {
    var body: some View {
        LottieView(animation: .named("ProgressIndicator"))
            .looping()
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 328, height: 90)
            .clipped()
            .accessibilityHidden(true)
    }
}
