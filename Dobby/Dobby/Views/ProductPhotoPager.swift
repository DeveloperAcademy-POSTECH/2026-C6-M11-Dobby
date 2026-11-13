import SwiftUI
import UIKit

struct ProductPhotoPager: UIViewControllerRepresentable {
    let photos: [GarmentPhoto]
    @Binding var selectedIndex: Int
    var onTransitionChange: ((Bool) -> Void)? = nil
    var onRotationAnimationChange: ((Bool) -> Void)? = nil
    var allowsDismissGesture = true
    var allowsPaging = true
    var onDismissDragChanged: ((CGFloat) -> Void)? = nil
    var onDismissDragEnded: ((CGFloat, CGFloat, Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(photos: photos, selection: $selectedIndex, onTransitionChange: onTransitionChange,
                    onRotationAnimationChange: onRotationAnimationChange,
                    onDismissDragChanged: onDismissDragChanged, onDismissDragEnded: onDismissDragEnded)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll,
            navigationOrientation: .horizontal, options: [.interPageSpacing: 0])
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.view.clipsToBounds = true
        controller.view.isAccessibilityElement = false
        context.coordinator.installDismissGesture(in: controller)
        context.coordinator.setInteraction(allowsPaging: allowsPaging, allowsDismissGesture: allowsDismissGesture)
        context.coordinator.show(selectedIndex, in: controller, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.selection = $selectedIndex
        context.coordinator.onTransitionChange = onTransitionChange
        context.coordinator.onRotationAnimationChange = onRotationAnimationChange
        context.coordinator.onDismissDragChanged = onDismissDragChanged
        context.coordinator.onDismissDragEnded = onDismissDragEnded
        context.coordinator.setInteraction(allowsPaging: allowsPaging, allowsDismissGesture: allowsDismissGesture)
        context.coordinator.show(selectedIndex, in: controller, animated: true)
    }

    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.delegate = nil
        controller.dataSource = nil
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
                             UIGestureRecognizerDelegate {
        let photos: [GarmentPhoto]
        var selection: Binding<Int>
        var onTransitionChange: ((Bool) -> Void)?
        var onRotationAnimationChange: ((Bool) -> Void)?
        var onDismissDragChanged: ((CGFloat) -> Void)?
        var onDismissDragEnded: ((CGFloat, CGFloat, Bool) -> Void)?
        fileprivate weak var dismissPan: UIPanGestureRecognizer?
        private weak var pagingScrollView: UIScrollView?
        private var pages: [Int: UIHostingController<ProductPhotoPage>] = [:]
        private var displayedIndex: Int?
        private var requestedIndex: Int?
        private var isActive = true
        private var isTransitioning = false
        private var pendingIndex: Int?
        private var allowsPaging = true
        private var allowsDismissGesture = true
        private var animatingPages: Set<Int> = []

        init(photos: [GarmentPhoto], selection: Binding<Int>, onTransitionChange: ((Bool) -> Void)?,
             onRotationAnimationChange: ((Bool) -> Void)?,
             onDismissDragChanged: ((CGFloat) -> Void)?,
             onDismissDragEnded: ((CGFloat, CGFloat, Bool) -> Void)?) {
            self.photos = photos
            self.selection = selection
            self.onTransitionChange = onTransitionChange
            self.onRotationAnimationChange = onRotationAnimationChange
            self.onDismissDragChanged = onDismissDragChanged
            self.onDismissDragEnded = onDismissDragEnded
        }

        fileprivate func installDismissGesture(in controller: UIPageViewController) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(dragToDismiss(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            controller.view.addGestureRecognizer(pan)
            // Decide direction before the page controller consumes the same
            // one-finger pan. A horizontal gesture immediately fails our
            // recognizer and continues into the existing page scroll view.
            for case let scroll as UIScrollView in controller.view.subviews {
                scroll.backgroundColor = .clear
                scroll.isOpaque = false
                scroll.panGestureRecognizer.require(toFail: pan)
                pagingScrollView = scroll
            }
            dismissPan = pan
        }

        fileprivate func setInteraction(allowsPaging: Bool, allowsDismissGesture: Bool) {
            self.allowsPaging = allowsPaging
            self.allowsDismissGesture = allowsDismissGesture
            pagingScrollView?.isScrollEnabled = allowsPaging && animatingPages.isEmpty
            dismissPan?.isEnabled = allowsDismissGesture && animatingPages.isEmpty
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isActive, !isTransitioning, animatingPages.isEmpty, !photos.isEmpty,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view, onDismissDragChanged != nil,
                  !containsZoomedImage(in: view) else { return false }
            let velocity = pan.velocity(in: view.window ?? view)
            // Horizontal swipes belong to the page controller; upward image
            // movement and multi-touch zoom never begin a dismissal.
            return velocity.y > 0 && velocity.y > abs(velocity.x) * 1.15
        }

        @objc private func dragToDismiss(_ pan: UIPanGestureRecognizer) {
            guard isActive, let view = pan.view else { return }
            // The photo itself moves and scales under the finger. Measure in
            // window coordinates so that presentation transforms cannot feed
            // back into the next drag update or change the dismissal velocity.
            let coordinateView = view.window ?? view
            let distance = max(0, pan.translation(in: coordinateView).y)
            switch pan.state {
            case .began, .changed: onDismissDragChanged?(distance)
            case .ended: onDismissDragEnded?(distance, pan.velocity(in: coordinateView).y, false)
            case .cancelled, .failed: onDismissDragEnded?(0, 0, true)
            default: break
            }
        }

        private func containsZoomedImage(in view: UIView) -> Bool {
            if let scroll = view as? UIScrollView,
               scroll.isZooming || scroll.isZoomBouncing || scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                return true
            }
            return view.subviews.contains { containsZoomedImage(in: $0) }
        }

        fileprivate func invalidate() {
            isActive = false
            pendingIndex = nil
            onTransitionChange = nil
            onRotationAnimationChange = nil
            animatingPages.removeAll()
            onDismissDragChanged = nil
            onDismissDragEnded = nil
            if let dismissPan {
                dismissPan.delegate = nil
                dismissPan.view?.removeGestureRecognizer(dismissPan)
            }
            dismissPan = nil
            pages.removeAll()
        }

        fileprivate func show(_ index: Int, in controller: UIPageViewController, animated: Bool) {
            guard isActive, photos.indices.contains(index) else { return }
            let selectionChanged = index != requestedIndex
            requestedIndex = index
            if isTransitioning {
                if selectionChanged { pendingIndex = index }
                return
            }
            guard index != displayedIndex else { return }
            if displayedIndex != nil, !allowsPaging || !animatingPages.isEmpty {
                pendingIndex = index
                return
            }
            let direction: UIPageViewController.NavigationDirection = index < (displayedIndex ?? index)
                ? .reverse : .forward
            if !animated {
                controller.setViewControllers([page(at: index)], direction: direction, animated: false)
                displayedIndex = index
                reportTransition(false)
                return
            }
            isTransitioning = true
            reportTransition(true)
            controller.view.isUserInteractionEnabled = false
            controller.setViewControllers([page(at: index)], direction: direction, animated: true) {
                [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.finishTransition(in: controller)
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard isActive, allowsPaging, animatingPages.isEmpty,
                  let index = index(of: viewController), photos.indices.contains(index - 1) else { return nil }
            return page(at: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard isActive, allowsPaging, animatingPages.isEmpty,
                  let index = index(of: viewController), photos.indices.contains(index + 1) else { return nil }
            return page(at: index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            guard isActive else { return }
            isTransitioning = true
            reportTransition(true)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            finishTransition(in: pageViewController)
        }

        private func finishTransition(in controller: UIPageViewController) {
            guard isActive else { return }
            displayedIndex = controller.viewControllers?.first.flatMap { index(of: $0) }
            isTransitioning = false
            controller.view.isUserInteractionEnabled = true
            if let pending = pendingIndex {
                pendingIndex = nil
                if pending != displayedIndex {
                    show(pending, in: controller, animated: true)
                    return
                }
            }
            if let displayedIndex, selection.wrappedValue != displayedIndex {
                selection.wrappedValue = displayedIndex
            }
            reportTransition(false)
        }

        private func reportTransition(_ transitioning: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.isTransitioning == transitioning else { return }
                self.onTransitionChange?(transitioning)
            }
        }

        private func index(of controller: UIViewController) -> Int? {
            pages.first { $0.value === controller }?.key
        }

        private func reportRotation(_ rotating: Bool, at index: Int) {
            guard isActive else { return }
            if rotating { animatingPages.insert(index) } else { animatingPages.remove(index) }
            setInteraction(allowsPaging: allowsPaging, allowsDismissGesture: allowsDismissGesture)
            let isAnimating = !animatingPages.isEmpty
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, (!self.animatingPages.isEmpty) == isAnimating else { return }
                self.onRotationAnimationChange?(isAnimating)
            }
        }

        private func page(at index: Int) -> UIHostingController<ProductPhotoPage> {
            if let cached = pages[index] { return cached }
            let controller = UIHostingController(rootView: ProductPhotoPage(photo: photos[index], index: index,
                onRotationAnimationChange: { [weak self] in self?.reportRotation($0, at: index) }))
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            controller.view.clipsToBounds = true
            controller.view.isAccessibilityElement = false
            pages[index] = controller
            return controller
        }
    }
}

private struct ProductPhotoPage: View {
    let photo: GarmentPhoto
    let index: Int
    let onRotationAnimationChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: CGImage?
    @State private var imageRequestID: UUID?
    @State private var displayAngle: Double
    @State private var animationID: UUID?

    init(photo: GarmentPhoto, index: Int, onRotationAnimationChange: @escaping (Bool) -> Void) {
        self.photo = photo
        self.index = index
        self.onRotationAnimationChange = onRotationAnimationChange
        _displayAngle = State(initialValue:
            Double(ProductPhotoRotationLayout.normalizedQuarterTurns(photo.productRotationQuarterTurns ?? 0)) * 90)
    }

    private var originalRequest: ProductThumbnailRequest {
        // Product-only variants are still saved for thumbnails and export.
        // The gallery keeps one original raster so rotation never decodes a
        // replacement mid-animation or flashes a new loading canvas.
        .init(url: GarmentStore.photosDirectory.appending(path: photo.fileName), maximumPixelSize: 2400)
    }

    var body: some View {
        Group {
            if let image {
                ProductPhotoRotatingImage(image: image, angleDegrees: displayAngle)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("제품 사진 \(index + 1)")
        .accessibilityValue("회전 \(ProductPhotoRotationLayout.normalizedQuarterTurns(photo.productRotationQuarterTurns ?? 0) * 90)도")
        .accessibilityIdentifier("product-gallery.photo.\(index + 1)")
        .task(id: originalRequest) {
            let request = originalRequest
            let requestID = UUID()
            imageRequestID = requestID
            image = nil
            let decoded = await ProductThumbnailLoader.shared.image(for: request)
            guard !Task.isCancelled, imageRequestID == requestID, originalRequest == request else { return }
            image = decoded?.image
        }
        .onChange(of: photo.productRotationQuarterTurns ?? 0) { previous, next in
            rotate(from: previous, to: next)
        }
        .onDisappear { finishAnimation() }
    }

    private func rotate(from previous: Int, to next: Int) {
        let target = ProductPhotoRotationLayout.nextDisplayAngle(currentDegrees: displayAngle,
            previousQuarterTurns: previous, nextQuarterTurns: next)
        guard target != displayAngle else { return }
        guard image != nil, !reduceMotion else {
            finishAnimation()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { displayAngle = target }
            return
        }
        let identifier = UUID()
        animationID = identifier
        onRotationAnimationChange(true)
        withAnimation(.easeInOut(duration: 0.32), completionCriteria: .logicallyComplete) {
            displayAngle = target
        } completion: {
            guard animationID == identifier else { return }
            finishAnimation()
        }
    }

    private func finishAnimation() {
        guard animationID != nil else { return }
        animationID = nil
        onRotationAnimationChange(false)
    }
}
