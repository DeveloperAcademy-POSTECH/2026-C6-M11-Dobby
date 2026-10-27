import Lottie
import SwiftUI

struct UploadLoadingAnimation: View {
    var body: some View {
        LottieView(animation: .named("ProgressIndicator"))
            .looping()
            .frame(width: 100, height: 100)
            .accessibilityHidden(true)
    }
}
