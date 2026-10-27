import SwiftUI
import UIKit

struct ProductPhotoPager: UIViewControllerRepresentable {
    let photos: [GarmentPhoto]
    @Binding var selectedIndex: Int
    var onTransitionChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(photos: photos, selection: $selectedIndex, onTransitionChange: onTransitionChange)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll,
            navigationOrientation: .horizontal, options: [.interPageSpacing: 0])
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        controller.view.clipsToBounds = true
        controller.view.isAccessibilityElement = false
        context.coordinator.show(selectedIndex, in: controller, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.selection = $selectedIndex
        context.coordinator.onTransitionChange = onTransitionChange
        context.coordinator.show(selectedIndex, in: controller, animated: true)
    }

    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        coordinator.invalidate()
        controller.delegate = nil
        controller.dataSource = nil
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let photos: [GarmentPhoto]
        var selection: Binding<Int>
        var onTransitionChange: ((Bool) -> Void)?
        private var pages: [Int: UIHostingController<ProductPhotoPage>] = [:]
        private var displayedIndex: Int?
        private var requestedIndex: Int?
        private var isActive = true
        private var isTransitioning = false
        private var pendingIndex: Int?

        init(photos: [GarmentPhoto], selection: Binding<Int>, onTransitionChange: ((Bool) -> Void)?) {
            self.photos = photos
            self.selection = selection
            self.onTransitionChange = onTransitionChange
        }

        fileprivate func invalidate() {
            isActive = false
            pendingIndex = nil
            onTransitionChange = nil
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
            guard isActive, let index = index(of: viewController), photos.indices.contains(index - 1) else { return nil }
            return page(at: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard isActive, let index = index(of: viewController), photos.indices.contains(index + 1) else { return nil }
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

        private func page(at index: Int) -> UIHostingController<ProductPhotoPage> {
            if let cached = pages[index] { return cached }
            let controller = UIHostingController(rootView: ProductPhotoPage(photo: photos[index], index: index))
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .black
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

    var body: some View {
        StoredProductPhotoView(photo: photo, maximumPixelSize: 2400, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("제품 사진 \(index + 1)")
            .accessibilityIdentifier("product-gallery.photo.\(index + 1)")
    }
}
