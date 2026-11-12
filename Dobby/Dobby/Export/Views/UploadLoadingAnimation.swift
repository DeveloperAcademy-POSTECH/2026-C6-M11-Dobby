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
    // Shared tape artwork, with the designer's position track and composition timing.
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
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipped()
            .accessibilityHidden(true)
    }

    private var playbackMode: LottiePlaybackMode {
        if reduceMotion {
            return .paused(at: .progress(0))
        }
        guard scenePhase == .active else {
            return .paused(at: .currentFrame)
        }
        // Each resource owns its timing. AI uses the designer's 40-frame composition.
        return .playing(.fromProgress(0, toProgress: 1, loopMode: .loop))
    }
}

#Preview("업로드 애니메이션", traits: .sizeThatFitsLayout) {
    UploadLoadingAnimation(source: .upload, width: 280, height: 280)
        .background(Color(.brandNeutralWhite))
}

#Preview("AI 정보 애니메이션", traits: .sizeThatFitsLayout) {
    UploadLoadingAnimation(source: .aiInformation, width: 328, height: 90)
        .background(Color(.brandNeutralWhite))
}
