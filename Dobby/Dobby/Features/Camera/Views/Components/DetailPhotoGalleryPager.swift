import SwiftUI
import UIKit

/// Keep the outgoing page alive until the system's paging transition finishes.
/// A TabView can discard a selected photo before its replacement is selected.
struct DetailPhotoGalleryPager<Item: Identifiable, Page: View>: UIViewControllerRepresentable where Item.ID == String {
    let items: [Item]
    @Binding var focusedID: String
    let reduceMotion: Bool
    let onTransitionChanged: (Bool) -> Void
    @ViewBuilder var page: (Item) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        context.coordinator.update(self, in: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.update(self, in: controller)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var parent: DetailPhotoGalleryPager
        private var previousIDs: [String] = []
        private var controllers: [String: DetailPhotoGalleryPageController<Page>] = [:]
        private var currentID: String?
        private var isTransitioning = false
        private var transitionRevision = 0

        init(_ parent: DetailPhotoGalleryPager) { self.parent = parent }

        func update(_ parent: DetailPhotoGalleryPager, in controller: UIPageViewController) {
            self.parent = parent
            // Save the latest request while a swipe/programmatic transition is in flight.
            // Applying another setViewControllers during it can jump or assert in UIKit.
            guard !isTransitioning else { return }
            let ids = parent.items.map(\.id)
            guard let selection = DetailPhotoGalleryPageSelection(focusedID: parent.focusedID,
                currentID: currentID, previousIDs: previousIDs, ids: ids) else { return }
            previousIDs = ids
            guard currentID != selection.id,
                  let destination = pageController(for: selection.id) else {
                pruneControllers()
                return
            }
            // Filmstrip scrubbing must stay immediate. Only removal of the
            // currently displayed page needs an automatic adjacent-page slide.
            let removingCurrentPage = currentID.map { !ids.contains($0) } ?? false
            let animated = removingCurrentPage && !parent.reduceMotion
            if !animated {
                controller.setViewControllers([destination], direction: .forward, animated: false)
                currentID = selection.id
                pruneControllers()
                return
            }
            isTransitioning = true
            notifyTransition(true)
            controller.setViewControllers([destination],
                direction: selection.movesBackwards ? .reverse : .forward, animated: true) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.currentID = self.id(for: controller.viewControllers?.first) ?? selection.id
                self.isTransitioning = false
                self.pruneControllers()
                self.notifyTransition(false)
                self.update(self.parent, in: controller)
            }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            adjacentPage(to: viewController, offset: -1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            adjacentPage(to: viewController, offset: 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
            notifyTransition(true)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let visibleID = id(for: pageViewController.viewControllers?.first) {
                currentID = visibleID
                parent.focusedID = visibleID
            }
            // A cancelled swipe keeps both the current page and the filmstrip selection.
            isTransitioning = false
            notifyTransition(false)
            update(parent, in: pageViewController)
        }

        private func adjacentPage(to controller: UIViewController, offset: Int) -> UIViewController? {
            let ids = parent.items.map(\.id)
            guard let id = id(for: controller), let index = ids.firstIndex(of: id),
                  ids.indices.contains(index + offset) else { return nil }
            return pageController(for: ids[index + offset])
        }

        private func pageController(for id: String) -> DetailPhotoGalleryPageController<Page>? {
            if let cached = controllers[id] { return cached }
            guard let item = parent.items.first(where: { $0.id == id }) else { return nil }
            let controller = DetailPhotoGalleryPageController(photoID: id, rootView: parent.page(item))
            controller.safeAreaRegions = []
            controller.view.backgroundColor = .clear
            controllers[id] = controller
            return controller
        }

        private func id(for controller: UIViewController?) -> String? {
            (controller as? DetailPhotoGalleryPageController<Page>)?.photoID
        }

        private func pruneControllers() {
            // Limit decoded full-size pages to the current photo and its neighbours.
            let ids = parent.items.map(\.id)
            let index = currentID.flatMap { ids.firstIndex(of: $0) } ?? 0
            let retained = Set(ids.enumerated().filter { abs($0.offset - index) <= 1 }.map(\.element))
            controllers = controllers.filter { retained.contains($0.key) }
        }

        private func notifyTransition(_ transitioning: Bool) {
            // updateUIViewController must not synchronously publish SwiftUI state changes.
            transitionRevision += 1
            let revision = transitionRevision
            let callback = parent.onTransitionChanged
            Task { @MainActor [weak self] in
                guard self?.transitionRevision == revision else { return }
                callback(transitioning)
            }
        }
    }
}

/// UIKit may retain a page after it leaves our decoded-page cache. Its identity
/// must remain available for later data-source and completed-swipe callbacks.
@MainActor
final class DetailPhotoGalleryPageController<Page: View>: UIHostingController<Page> {
    let photoID: String

    init(photoID: String, rootView: Page) {
        self.photoID = photoID
        super.init(rootView: rootView)
    }

    required dynamic init?(coder: NSCoder) {
        fatalError("Gallery pages are created with a photo identity and SwiftUI content")
    }
}

/// Choose the adjacent surviving photo in the original order. Deleting the last
/// photo moves backwards; deleting an interior photo advances to the next one.
struct DetailPhotoGalleryPageSelection: Equatable {
    let id: String
    let movesBackwards: Bool

    init?(focusedID: String, currentID: String?, previousIDs: [String], ids: [String]) {
        guard !ids.isEmpty else { return nil }
        let previousIndex = previousIDs.firstIndex(of: currentID ?? focusedID) ?? 0
        id = ids.contains(focusedID) ? focusedID : ids[min(previousIndex, ids.count - 1)]
        let destinationIndex = previousIDs.firstIndex(of: id) ?? ids.firstIndex(of: id) ?? 0
        movesBackwards = destinationIndex < previousIndex
    }
}
