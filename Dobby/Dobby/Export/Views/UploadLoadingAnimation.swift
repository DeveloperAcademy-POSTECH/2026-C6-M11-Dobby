import Lottie
import SwiftUI

struct UploadLoadingAnimation: View {
    enum Source: Equatable {
        case upload
        case aiInformation
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private static let uploadAnimation = LottieAnimation.named("ProgressIndicator")
    // Designer-supplied square AI composition, including its embedded images.
    private static let aiAnimation = LottieAnimation.named("AIProgressIndicator")

    let source: Source
    let width: CGFloat
    let height: CGFloat

    init(source: Source = .upload, width: CGFloat = 328, height: CGFloat = 90) {
        self.source = source
        self.width = width
        self.height = height
    }

    var body: some View {
        LottieView(animation: source == .upload ? Self.uploadAnimation : Self.aiAnimation)
            .playbackMode(playbackMode)
            .backgroundBehavior(.pauseAndRestore)
            .resizable()
            .aspectRatio(contentMode: source == .aiInformation ? .fit : .fill)
            .frame(width: width, height: height)
            .clipped()
            .accessibilityHidden(true)
    }

    private var playbackMode: LottiePlaybackMode {
        if reduceMotion {
            // AI begins with an empty reveal; frame 45 keeps both tape strips visible.
            return .paused(at: .progress(source == .aiInformation ? 45.0 / 379.0 : 0))
        }
        guard scenePhase == .active else {
            return .paused(at: .currentFrame)
        }
        // Play each supplied composition at its own frame rate and loop it in full.
        return .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
    }
}

#Preview("업로드 애니메이션", traits: .sizeThatFitsLayout) {
    UploadLoadingAnimation(source: .upload, width: 280, height: 280)
        .background(Color(.brandNeutralWhite))
}

#Preview("AI 정보 애니메이션", traits: .sizeThatFitsLayout) {
    UploadLoadingAnimation(source: .aiInformation, width: 280, height: 280)
        .background(Color(.brandNeutralWhite))
}
