import SwiftUI

/// Figma 5561:28941 → 5561:28976. Only the two clothing rows move;
/// the original vector logo stays still. The designer supplied the two states
/// without timing data; the requested movement duration is 1500 milliseconds,
/// rather than a timing value exported from Figma.
struct LaunchSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasMoved = false

    let onCompletion: () -> Void

    private static let referenceSize = CGSize(width: 402, height: 874)
    private static let movementDuration: TimeInterval = 1.5

    private static let upperItems: [(asset: String, x: CGFloat)] = [
        ("LaunchSplashRustPants", -48),
        ("LaunchSplashStripedTShirt", 113),
        ("LaunchSplashGrayPants", 274),
        ("LaunchSplashRustPants", 429),
        ("LaunchSplashStripedTShirt", 590),
        ("LaunchSplashGrayPants", 751)
    ]

    private static let lowerItems: [(asset: String, x: CGFloat)] = [
        ("LaunchSplashPlaidShorts", -481),
        ("LaunchSplashJacket", -320),
        ("LaunchSplashPlaidShirt", -159),
        ("LaunchSplashPlaidShorts", -4),
        ("LaunchSplashJacket", 157),
        ("LaunchSplashPlaidShirt", 318)
    ]

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / Self.referenceSize.width

            ZStack {
                Color("LaunchSplashBackground")

                clothingRow(Self.upperItems, scale: scale, width: geometry.size.width)
                    .offset(x: hasMoved ? -270 * scale : 0)
                    .position(x: geometry.size.width / 2,
                              y: geometry.size.height * 216 / Self.referenceSize.height)

                Image("LaunchSplashLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 168.973 * scale, height: 47.504 * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                clothingRow(Self.lowerItems, scale: scale, width: geometry.size.width)
                    .offset(x: hasMoved ? 306 * scale : 0)
                    .position(x: geometry.size.width / 2,
                              y: geometry.size.height * 658 / Self.referenceSize.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("앱을 시작하고 있어요")
        .task { await playLaunch() }
    }

    private func clothingRow(_ items: [(asset: String, x: CGFloat)],
                             scale: CGFloat, width: CGFloat) -> some View {
        ZStack {
            ForEach(items.indices, id: \.self) { index in
                Image(items[index].asset)
                    .resizable()
                    .frame(width: 130 * scale, height: 140 * scale)
                    .position(x: (items[index].x + 65) * scale, y: 70 * scale)
            }
        }
        .frame(width: width, height: 140 * scale)
        .accessibilityHidden(true)
    }

    @MainActor
    private func playLaunch() async {
        // This view only exists during the process's initial launch, so returning
        // from the background never restarts the animation or blocks navigation.
        if reduceMotion {
            await Task.yield()
        } else {
            // Commit the static launch composition before beginning the move.
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: Self.movementDuration)) {
                hasMoved = true
            }
            do {
                try await Task.sleep(for: .seconds(Self.movementDuration))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        onCompletion()
    }
}
