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
        view.backControl.isEnabled = canGoBack
        view.backControl.accessibilityIdentifier = backIdentifier
        view.nextControl.isEnabled = canContinue
        view.nextControl.isHidden = isBusy
        view.busyView.isHidden = !isBusy
        view.busyView.accessibilityValue = busyDescription
        view.accessibilityElements = [view.backControl, view.bar, isBusy ? view.busyView : view.nextControl]
        if isBusy { view.spinner.startAnimating() } else { view.spinner.stopAnimating() }
    }

    final class Container: UIView {
        let bar = UINavigationBar()
        let item = UINavigationItem(title: "실측 결과")
        let spinner = UIActivityIndicatorView(style: .medium)
        var onBack: (() -> Void)?
        var onContinue: (() -> Void)?
        lazy var backControl: UIButton = {
            let control = glassControl(width: 44)
            var configuration = control.configuration
            configuration?.image = UIImage(systemName: "chevron.left", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
            control.configuration = configuration
            control.accessibilityLabel = "뒤로가기"
            control.accessibilityHint = "실측 촬영 화면으로 돌아갑니다"
            control.addTarget(self, action: #selector(goBack), for: .touchUpInside)
            return control
        }()
        lazy var nextControl: UIButton = {
            let control = glassControl(width: 60)
            var configuration = control.configuration
            configuration?.title = "다음"
            configuration?.baseForegroundColor = UIColor(named: "BrandMain950") ?? .label
            configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming
                attributes.font = UIFont(name: "Pretendard-SemiBold", size: 17)
                    ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
                attributes.kern = -0.43
                return attributes
            }
            control.configuration = configuration
            control.accessibilityLabel = "다음"
            control.accessibilityHint = "사진과 확인한 측정 결과를 저장하고 다음 단계로 이동합니다"
            control.accessibilityIdentifier = "confirmGarmentMeasurement"
            control.addTarget(self, action: #selector(proceed), for: .touchUpInside)
            return control
        }()
        lazy var busyView: UIView = {
            let container = UIView()
            container.addSubview(spinner)
            container.isAccessibilityElement = true
            container.accessibilityLabel = "다음"
            container.accessibilityIdentifier = "confirmGarmentMeasurement"
            return container
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
            // Standalone UINavigationBar items are internally reduced to 36pt.
            // Keep its native title/VoiceOver navigation container, while the
            // system glass controls retain the design's full 44pt bounds.
            addSubview(backControl)
            addSubview(nextControl)
            addSubview(busyView)
            spinner.color = UIColor(named: "BrandMain950") ?? .label
            spinner.isUserInteractionEnabled = false
            spinner.isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func glassControl(width: CGFloat) -> UIButton {
            var configuration = UIButton.Configuration.glass()
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            let button = UIButton(configuration: configuration)
            button.frame.size = CGSize(width: width, height: ProductCreationHeaderLayout.toolbarHeight)
            return button
        }

        @objc private func goBack() { onBack?() }
        @objc private func proceed() { onContinue?() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = ProductCreationHeaderLayout.toolbarHeight
            bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            backControl.frame = CGRect(x: 16, y: 0, width: 44, height: height)
            let trailing = CGRect(x: max(0, bounds.width - 16 - 60), y: 0, width: 60, height: height)
            nextControl.frame = trailing
            busyView.frame = trailing
            spinner.frame = CGRect(x: 20, y: (height - 20) / 2, width: 20, height: 20)
        }
    }
}
