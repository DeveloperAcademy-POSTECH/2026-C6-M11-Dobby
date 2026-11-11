import SwiftUI
import UIKit

/// The Figma Toolbar - Top - iPhone uses the platform navigation bar and its
/// glass bar buttons. Give that native bar a real 44pt hit area; do not move
/// toolbar labels outside the navigation bar's bounds to imitate its spacing.
struct MeasurementResultNavigationBar: UIViewRepresentable {
    let canGoBack: Bool
    let canContinue: Bool
    let isBusy: Bool
    let busyDescription: String
    let backIdentifier: String
    let onBack: () -> Void
    let onContinue: () -> Void

    func makeUIView(context: Context) -> Container {
        let view = Container()
        configure(view)
        return view
    }

    func updateUIView(_ view: Container, context: Context) { configure(view) }

    private func configure(_ view: Container) {
        view.onBack = onBack
        view.onContinue = onContinue
        view.backButton.isEnabled = canGoBack
        view.backButton.accessibilityIdentifier = backIdentifier
        view.nextButton.isEnabled = canContinue
        let selected = isBusy ? view.busyItem : view.nextButton
        if view.item.rightBarButtonItem !== selected { view.item.rightBarButtonItem = selected }
        view.busyItem.accessibilityValue = busyDescription
        view.busyItem.customView?.accessibilityValue = busyDescription
        if isBusy { view.spinner.startAnimating() } else { view.spinner.stopAnimating() }
    }

    final class Container: UIView {
        let bar = UINavigationBar()
        let item = UINavigationItem(title: "실측 결과")
        let spinner = UIActivityIndicatorView(style: .medium)
        var onBack: (() -> Void)?
        var onContinue: (() -> Void)?
        lazy var backButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
            style: .plain, target: self, action: #selector(goBack))
        lazy var nextButton = UIBarButtonItem(title: "다음", style: .plain,
                                             target: self, action: #selector(proceed))
        lazy var busyItem: UIBarButtonItem = {
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 60, height: 44))
            spinner.frame = CGRect(x: 20, y: 12, width: 20, height: 20)
            container.addSubview(spinner)
            container.isAccessibilityElement = true
            container.accessibilityLabel = "다음"
            container.accessibilityIdentifier = "confirmGarmentMeasurement"
            return UIBarButtonItem(customView: container)
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                                              .foregroundColor: UIColor.label, .kern: -0.43]
            bar.standardAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactAppearance = appearance
            bar.isTranslucent = true
            bar.setItems([item], animated: false)
            addSubview(bar)
            item.leftBarButtonItem = backButton
            item.rightBarButtonItem = nextButton
            backButton.tintColor = .label
            backButton.accessibilityLabel = "뒤로가기"
            backButton.accessibilityHint = "실측 촬영 화면으로 돌아갑니다"
            nextButton.tintColor = UIColor(named: "BrandMain950") ?? .label
            nextButton.setTitleTextAttributes([
                .font: UIFont(name: "Pretendard-SemiBold", size: 17)
                    ?? UIFont.systemFont(ofSize: 17, weight: .semibold), .kern: -0.43], for: .normal)
            nextButton.accessibilityLabel = "다음"
            nextButton.accessibilityHint = "사진과 확인한 측정 결과를 저장하고 다음 단계로 이동합니다"
            nextButton.accessibilityIdentifier = "confirmGarmentMeasurement"
            busyItem.accessibilityLabel = "다음"
            busyItem.accessibilityIdentifier = "confirmGarmentMeasurement"
            spinner.color = UIColor(named: "BrandMain950") ?? .label
            spinner.isUserInteractionEnabled = false
            spinner.isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func goBack() { onBack?() }
        @objc private func proceed() { onContinue?() }

        override func layoutSubviews() {
            super.layoutSubviews()
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 44)
        }
    }
}
