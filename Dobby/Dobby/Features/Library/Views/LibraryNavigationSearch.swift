import SwiftUI
import UIKit

struct LibraryHeaderMetrics: Equatable {
    var statusBarHeight: CGFloat = 0
    var height: CGFloat = 0
    var bottomBarHeight: CGFloat = 0
    var windowHeight: CGFloat = 0
}

/// Keeps the navigation toolbar fixed while independently collapsing the search field.
struct LibraryNavigationSearch: UIViewControllerRepresentable {
    @Binding var text: String
    /// The committed query; composing text stays visible without changing the results.
    @Binding var query: String
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

    final class Coordinator: NSObject, UISearchBarDelegate {
        var configuration: LibraryNavigationSearch
        private let search = UISearchBar()
        private let searchContainer = UIView()
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
        private var pendingSearch: Task<Void, Never>?
        private let statusBackground = UIView()
        private var previousInsetAdjustment: UIScrollView.ContentInsetAdjustmentBehavior = .automatic

        init(configuration: LibraryNavigationSearch) {
            self.configuration = configuration
            super.init()
            search.delegate = self
            searchContainer.backgroundColor = UIColor(LibraryStyle.background)
            // The native search field casts a soft shadow outside this region.
            // Clipping it at the bottom creates a visible horizontal background seam.
            searchContainer.clipsToBounds = false
            searchContainer.addSubview(search)
            search.placeholder = "Search"
            search.searchBarStyle = .minimal
            search.backgroundColor = .clear
            search.backgroundImage = UIImage()
            let field = search.searchTextField
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
                owner.definesPresentationContext = true
                navigation.setNavigationBarHidden(false, animated: false)
            }
            // Search owns only the area below the toolbar. Neither collapsing
            // nor focusing it transforms the navigation bar or its buttons.
            if searchContainer.superview !== navigation.view {
                navigation.view.insertSubview(searchContainer, belowSubview: navigation.navigationBar)
            }
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

            if search.text != configuration.text { search.text = configuration.text }
            if !configuration.isFocused && search.searchTextField.isFirstResponder {
                search.resignFirstResponder()
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
            pendingSearch?.cancel()
            pendingSearch = nil
            animator?.stopAnimation(true)
            animator = nil
            statusBackground.removeFromSuperview()
            searchContainer.removeFromSuperview()
            collapseOffset = 0
            headerHeight = 0
            reportedMetrics = nil
            isRestoringSearch = true
            search.resignFirstResponder()
            contentScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(didPan(_:)))
            contentScrollView?.contentInsetAdjustmentBehavior = previousInsetAdjustment
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
            guard searchContainer.window != nil else { return }
            let statusHeight = navigation.view.window?.safeAreaInsets.top ?? 0
            // The list scrolls behind the header, but never over the clock or Dynamic Island.
            if statusBackground.superview !== navigation.view {
                navigation.view.addSubview(statusBackground)
            }
            statusBackground.frame = CGRect(x: 0, y: 0, width: navigation.view.bounds.width, height: statusHeight)
            let bar = navigation.navigationBar
            let barBottom = bar.convert(bar.bounds, to: navigation.view).maxY
            let searchHeight = max(56, search.sizeThatFits(CGSize(width: navigation.view.bounds.width, height: 0)).height)
            headerHeight = searchHeight
            // UISearchBar supplies eight points internally. Keep the original
            // navigation search field's sixteen-point horizontal inset.
            search.bounds = CGRect(x: 0, y: 0, width: max(0, navigation.view.bounds.width - 16), height: searchHeight)
            search.center = CGPoint(x: navigation.view.bounds.width / 2, y: searchHeight / 2)
            searchContainer.frame = CGRect(x: 0, y: barBottom, width: navigation.view.bounds.width,
                                           height: max(0, searchHeight - collapseOffset))
            let height = (barBottom - statusHeight + searchHeight).rounded()
            guard height > 0 else { return }
            let metrics = LibraryHeaderMetrics(
                statusBarHeight: statusHeight, height: height,
                bottomBarHeight: navigation.tabBarController?.tabBar.bounds.height
                    ?? navigation.view.window?.safeAreaInsets.bottom ?? 0,
                windowHeight: navigation.view.window?.bounds.height ?? navigation.view.bounds.height
            )
            guard reportedMetrics != metrics else { return }
            reportedMetrics = metrics
            DispatchQueue.main.async { [weak self] in
                guard let self, self.owner != nil, self.reportedMetrics == metrics else { return }
                self.configuration.metrics = metrics
            }
        }

        private func apply(offset: CGFloat) {
            guard navigation != nil else { return }
            collapseOffset = min(max(0, offset), headerHeight)
            let progress = headerHeight > 0 ? collapseOffset / headerHeight : 0
            search.transform = CGAffineTransform(translationX: 0,
                y: UIAccessibility.isReduceMotionEnabled ? 0 : -collapseOffset)
            search.alpha = 1 - progress
            var frame = searchContainer.frame
            frame.size.height = max(0, headerHeight - collapseOffset)
            searchContainer.frame = frame
            searchContainer.isUserInteractionEnabled = progress < 0.95
            searchContainer.accessibilityElementsHidden = progress >= 0.95
        }

        private func interruptAnimation() {
            guard let animator else { return }
            let currentOffset = headerHeight - (searchContainer.layer.presentation()?.bounds.height
                ?? searchContainer.bounds.height)
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

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard !isRestoringSearch, owner != nil else { return }
            let text = search.text ?? ""
            if configuration.text != text { configuration.text = text }
            pendingSearch?.cancel()
            pendingSearch = nil
            let field = search.searchTextField
            guard field.markedTextRange == nil else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                commitSearch()
                return
            }
            pendingSearch = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                guard !Task.isCancelled, let self,
                      self.search.text == text,
                      self.search.searchTextField.markedTextRange == nil else { return }
                self.commitSearch()
            }
        }

        private func commitSearch() {
            pendingSearch?.cancel()
            pendingSearch = nil
            guard !isRestoringSearch, owner != nil,
                  search.searchTextField.markedTextRange == nil else { return }
            let text = search.text ?? ""
            if configuration.text != text { configuration.text = text }
            if configuration.query != text { configuration.query = text }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            configuration.isFocused = true
            navigation?.hidesBarsOnSwipe = false
            settle(at: 0, animated: true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            configuration.isFocused = false
            commitSearch()
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.searchTextField.unmarkText()
            commitSearch()
            searchBar.resignFirstResponder()
        }
    }
}
