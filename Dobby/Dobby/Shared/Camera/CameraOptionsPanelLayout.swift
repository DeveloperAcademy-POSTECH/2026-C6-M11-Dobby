import SwiftUI

/// Native-camera proportions, anchored to the 4:3 black region rather than the
/// currently selected ratio. Changing a ratio must not move its own controls.
nonisolated struct CameraOptionsPanelLayout: Equatable {
    let frame: CGRect
    let bottomContentPadding: CGFloat

    init(containerSize: CGSize, bottomSafeAreaInset: CGFloat = 0) {
        let width = Double(containerSize.width), height = Double(containerSize.height)
        guard width.isFinite, height.isFinite, width > 32, height > 32,
              bottomSafeAreaInset.isFinite, bottomSafeAreaInset >= 0,
              let reference = MeasurementCameraChromeLayout.photoViewport(
                containerWidth: width, containerHeight: height,
                photoAspectRatio: width > height ? 4.0 / 3 : 3.0 / 4) else {
            frame = .zero; bottomContentPadding = 20; return
        }
        let margin = 8.0, photoGap = 16.0
        let landscape = width > height
        let x = landscape ? reference.x + reference.width + margin : margin
        let panelWidth = width - x - margin
        let availableHeight = landscape ? height - margin * 2
            : height - margin - reference.y - reference.height - photoGap
        // Scroll the content on short windows. The 44pt minimum is a compact
        // fallback when the reference region cannot contain even one control.
        let panelHeight = min(height - margin * 2,
            max(44, min(panelWidth / 2.1, availableHeight)))
        guard panelWidth >= 44, panelHeight >= 44 else {
            frame = .zero; bottomContentPadding = 20; return
        }
        frame = CGRect(x: x, y: height - margin - panelHeight,
            width: panelWidth, height: panelHeight)
        // The panel background extends near the screen edge; keep its content
        // above the home indicator without subtracting the safe area twice.
        bottomContentPadding = max(20, min(34, bottomSafeAreaInset - margin))
    }
}

/// One surface and size for menu, exposure and ratio. Children provide only
/// content here; their standalone presentations retain their original padding.
struct CameraOptionsPanelSurface<Content: View>: View {
    let layout: CameraOptionsPanelLayout
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) { paddedContent }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(width: layout.frame.width, height: layout.frame.height)
        .background(Color(white: 0.14), in: shape)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: shape)
        .clipShape(shape)
    }

    private var paddedContent: some View {
        content()
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, layout.bottomContentPadding)
            .frame(maxWidth: .infinity)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(48, layout.frame.height / 3), style: .continuous)
    }
}
