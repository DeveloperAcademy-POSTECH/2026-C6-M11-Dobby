import SwiftUI
import UIKit

struct LibraryHeaderMetrics: Equatable {
    var statusBarHeight: CGFloat = 0
    var height: CGFloat = 0
    var bottomBarHeight: CGFloat = 0
}

/// Moves and fades the native header without changing the list's viewport or insets.
struct LibraryNavigationSearch: UIViewControllerRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let allowsHiding: Bool
    let revealID: Int
    @Binding var metrics: LibraryHeaderMetrics

    func makeCoordinator() -> Coordinator { Coordinator(configuration: self) }

    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.coordinator = context.coordinator
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.attach(from: presenter)
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Presenter: UIViewController {
        weak var coordinator: Coordinator?
        var isVisible = false

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            coordinator?.attach(from: self)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            coordinator?.attach(from: self)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            coordinator?.attach(from: self)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            coordinator?.restore()
        }
    }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate {
        var configuration: LibraryNavigationSearch
        private let search = UISearchController(searchResultsController: nil)
        private weak var navigation: UINavigationController?
        private weak var owner: UIViewController?
        private weak var previousScrollView: UIScrollView?
        private weak var contentScrollView: UIScrollView?
        private var previousHidesBarsOnSwipe = false
        private var lastRevealID: Int?
        private var lastPanY: CGFloat = 0
        private var isRestoringSearch = false
        private var collapseOffset: CGFloat = 0
        private var headerHeight: CGFloat = 0
        private var reportedMetrics: LibraryHeaderMetrics?
        private var animator: UIViewPropertyAnimator?
        private var originalBarTransform = CGAffineTransform.identity
        private var originalBarAlpha: CGFloat = 1
        private let statusBackground = UIView()
        private var previousInsetAdjustment: UIScrollView.ContentInsetAdjustmentBehavior = .automatic

        init(configuration: LibraryNavigationSearch) {
            self.configuration = configuration
            super.init()
            search.obscuresBackgroundDuringPresentation = false
            search.hidesNavigationBarDuringPresentation = false
            search.automaticallyShowsCancelButton = false
            search.searchResultsUpdater = self
            search.searchBar.delegate = self
            search.searchBar.placeholder = "Search"
            search.searchBar.searchBarStyle = .minimal
            let field = search.searchBar.searchTextField
            statusBackground.backgroundColor = UIColor(LibraryStyle.background)
            statusBackground.isUserInteractionEnabled = false
            statusBackground.accessibilityElementsHidden = true
            statusBackground.layer.zPosition = 1000
            field.backgroundColor = .white
            field.font = .systemFont(ofSize: 17)
            field.textColor = UIColor(LibraryStyle.primary)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .search
            field.accessibilityIdentifier = "library.search"
            field.accessibilityLabel = "보관함 검색"
            field.accessibilityHint = "제품명이나 브랜드로 검색합니다."
        }

        func attach(from presenter: Presenter) {
            guard presenter.isVisible, presenter.viewIfLoaded?.window != nil,
                  let navigation = presenter.navigationController,
                  let owner = navigation.topViewController else { return }
            if self.owner !== owner {
                restore()
                self.navigation = navigation
                self.owner = owner
                previousScrollView = owner.contentScrollView(for: .top)
                previousHidesBarsOnSwipe = navigation.hidesBarsOnSwipe
                originalBarTransform = navigation.navigationBar.transform
                originalBarAlpha = navigation.navigationBar.alpha
                owner.definesPresentationContext = true
                navigation.setNavigationBarHidden(false, animated: false)
            }
            let item = owner.navigationItem
            if item.searchController !== search {
                item.searchController = search
                DispatchQueue.main.async { [weak self, weak presenter] in
                    guard let presenter else { return }
                    self?.attach(from: presenter)
                }
            }
            if item.preferredSearchBarPlacement != .stacked { item.preferredSearchBarPlacement = .stacked }
            if item.hidesSearchBarWhenScrolling { item.hidesSearchBarWhenScrolling = false }
            // SwiftUI owns the hosting scroll view, so drive the native header from
            // its pan gesture instead of allowing two independent bar hide gestures.
            if navigation.hidesBarsOnSwipe { navigation.hidesBarsOnSwipe = false }
            if let scroll = findContentScrollView(in: owner.view), contentScrollView !== scroll {
                contentScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(didPan(_:)))
                contentScrollView?.contentInsetAdjustmentBehavior = previousInsetAdjustment
                contentScrollView = scroll
                previousInsetAdjustment = scroll.contentInsetAdjustmentBehavior
                scroll.contentInsetAdjustmentBehavior = .never
                owner.setContentScrollView(scroll, for: .top)
                scroll.panGestureRecognizer.addTarget(self, action: #selector(didPan(_:)))
            }

            reportHeaderMetrics(in: navigation)

            if search.searchBar.text != configuration.text { search.searchBar.text = configuration.text }
            if !configuration.isFocused && search.searchBar.searchTextField.isFirstResponder {
                search.searchBar.resignFirstResponder()
            }
            if lastRevealID != configuration.revealID {
                let animated = lastRevealID != nil
                lastRevealID = configuration.revealID
                settle(at: 0, animated: animated)
            } else if !configuration.allowsHiding && collapseOffset > 0 {
                settle(at: 0, animated: true)
            }
            isRestoringSearch = false
        }

        func restore() {
            animator?.stopAnimation(true)
            animator = nil
            statusBackground.removeFromSuperview()
            if let bar = navigation?.navigationBar {
                bar.transform = originalBarTransform
                bar.alpha = originalBarAlpha
                bar.isUserInteractionEnabled = true
                bar.accessibilityElementsHidden = false
            }
            collapseOffset = 0
            headerHeight = 0
            reportedMetrics = nil
            isRestoringSearch = true
            search.isActive = false
            contentScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(didPan(_:)))
            contentScrollView?.contentInsetAdjustmentBehavior = previousInsetAdjustment
            if owner?.navigationItem.searchController === search {
                owner?.navigationItem.searchController = nil
            }
            navigation?.hidesBarsOnSwipe = previousHidesBarsOnSwipe
            navigation?.setNavigationBarHidden(false, animated: false)
            if let contentScrollView, owner?.contentScrollView(for: .top) === contentScrollView {
                owner?.setContentScrollView(previousScrollView, for: .top)
            }
            contentScrollView = nil
            previousScrollView = nil
            navigation = nil
            owner = nil
            lastRevealID = nil
        }

        @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
            let y = gesture.translation(in: gesture.view).y
            if gesture.state == .began {
                interruptAnimation()
                lastPanY = y
                return
            }
            guard configuration.allowsHiding, !configuration.isFocused,
                  let scroll = contentScrollView, headerHeight > 0 else { return }
            if gesture.state == .ended || gesture.state == .cancelled {
                let velocity = gesture.velocity(in: gesture.view).y
                let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
                let target: CGFloat
                if offset <= 0 || velocity > 100 {
                    target = 0
                } else if velocity < -100 {
                    target = headerHeight
                } else {
                    target = collapseOffset > headerHeight / 2 ? headerHeight : 0
                }
                settle(at: target, animated: true)
                return
            }
            guard gesture.state == .changed else { return }
            let delta = y - lastPanY
            lastPanY = y
            let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let scrollableHeight = scroll.contentSize.height + scroll.adjustedContentInset.top
                + scroll.adjustedContentInset.bottom - scroll.bounds.height
            if offset <= 0 || scrollableHeight <= 0 {
                apply(offset: 0)
            } else {
                apply(offset: collapseOffset - delta)
            }
        }

        private func reportHeaderMetrics(in navigation: UINavigationController) {
            guard search.searchBar.window != nil, search.searchBar.bounds.height > 0 else { return }
            let statusHeight = navigation.view.window?.safeAreaInsets.top ?? 0
            // The list scrolls behind the header, but never over the clock or Dynamic Island.
            if statusBackground.superview !== navigation.view {
                navigation.view.addSubview(statusBackground)
            }
            statusBackground.frame = CGRect(x: 0, y: 0, width: navigation.view.bounds.width, height: statusHeight)
            let bar = navigation.navigationBar
            // Undo our own translation when measuring the expanded header.
            let barBottom = bar.convert(bar.bounds, to: navigation.view).maxY + collapseOffset
            let searchBottom = search.searchBar.convert(search.searchBar.bounds, to: navigation.view).maxY + collapseOffset
            let height = (max(barBottom, searchBottom) - statusHeight).rounded()
            guard height > 0 else { return }
            headerHeight = height
            let metrics = LibraryHeaderMetrics(
                statusBarHeight: statusHeight, height: height,
                bottomBarHeight: navigation.tabBarController?.tabBar.bounds.height
                    ?? navigation.view.window?.safeAreaInsets.bottom ?? 0
            )
            guard reportedMetrics != metrics else { return }
            reportedMetrics = metrics
            DispatchQueue.main.async { [weak self] in
                guard let self, self.owner != nil, self.reportedMetrics == metrics else { return }
                self.configuration.metrics = metrics
            }
        }

        private func apply(offset: CGFloat) {
            guard let bar = navigation?.navigationBar else { return }
            collapseOffset = min(max(0, offset), headerHeight)
            let progress = headerHeight > 0 ? collapseOffset / headerHeight : 0
            let reducesMotion = UIAccessibility.isReduceMotionEnabled
            bar.transform = originalBarTransform.translatedBy(
                x: 0, y: reducesMotion ? 0 : -collapseOffset
            )
            bar.alpha = originalBarAlpha * (1 - progress)
            bar.isUserInteractionEnabled = progress < 0.95
            bar.accessibilityElementsHidden = progress >= 0.95
        }

        private func interruptAnimation() {
            guard let animator else { return }
            let currentOffset = -(navigation?.navigationBar.layer.presentation()?.affineTransform().ty
                ?? navigation?.navigationBar.transform.ty ?? 0)
            animator.stopAnimation(true)
            self.animator = nil
            apply(offset: currentOffset)
        }

        private func settle(at offset: CGFloat, animated: Bool) {
            interruptAnimation()
            if abs(collapseOffset - offset) < 0.1 {
                apply(offset: offset)
                return
            }
            guard animated, !UIAccessibility.isReduceMotionEnabled else {
                apply(offset: offset)
                return
            }
            let animator = UIViewPropertyAnimator(duration: 0.24, curve: .easeOut) { [weak self] in
                self?.apply(offset: offset)
            }
            self.animator = animator
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, self.animator === animator else { return }
                self.animator = nil
            }
            animator.startAnimation()
        }

        private func findContentScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.bounds.height > 200 {
                return scroll
            }
            for child in view.subviews {
                if let scroll = findContentScrollView(in: child) { return scroll }
            }
            return nil
        }

        func updateSearchResults(for searchController: UISearchController) {
            guard !isRestoringSearch, owner != nil else { return }
            let text = searchController.searchBar.text ?? ""
            if configuration.text != text { configuration.text = text }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            configuration.isFocused = true
            navigation?.hidesBarsOnSwipe = false
            settle(at: 0, animated: true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            configuration.isFocused = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}
