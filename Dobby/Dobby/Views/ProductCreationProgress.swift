import SwiftUI
import UIKit

/// Shared vertical rhythm of the three Figma capture/result headers.
/// On the 402×874 reference, status-safe y=62 gives photo y=146.
nonisolated enum ProductCreationHeaderLayout {
    static let progressHeight: CGFloat = 3
    static let segmentSpacing: CGFloat = 6
    static let progressToToolbar: CGFloat = 13
    static let toolbarHeight: CGFloat = 44
    static let toolbarBottomPadding: CGFloat = 10
    static let photoGap: CGFloat = 14

    static let navigationInset = progressHeight + progressToToolbar
    static let navigationHeight = toolbarHeight + toolbarBottomPadding
    static let toolbarToPhoto = toolbarBottomPadding + photoGap
    static let photoTop = navigationInset + navigationHeight + photoGap
}

/// The native toolbar and result layout use the same header rhythm.
nonisolated enum ProductCreationLayoutMetrics {
    static let headerHeight = ProductCreationHeaderLayout.navigationInset + ProductCreationHeaderLayout.navigationHeight
    static let photoGap = ProductCreationHeaderLayout.photoGap
}

enum ProductCreationStage: Int, CaseIterable {
    case measurement = 1, measurementResult, details, information

    var title: String {
        switch self {
        case .measurement: "실측"
        case .measurementResult: "실측 결과"
        case .details: "제품 상세 촬영"
        case .information: "정보 입력"
        }
    }
}

/// Figma's full-width, four-segment progress bar. The current stage is filled too.
struct ProductCreationProgress: UIViewRepresentable {
    let stage: ProductCreationStage

    func makeUIView(context: Context) -> ProductCreationProgressBar {
        ProductCreationProgressBar(stage: stage)
    }

    func updateUIView(_ view: ProductCreationProgressBar, context: Context) {
        view.configure(stage: stage)
    }
}

final class ProductCreationProgressBar: UIView {
    private let segments = (0..<4).map { _ in UIView() }

    init(stage: ProductCreationStage) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.zPosition = 1000
        isAccessibilityElement = true
        accessibilityLabel = "촬영 및 등록 진행 단계"
        for (index, segment) in segments.enumerated() {
            // The design's large radius resolves to half of the 3pt segment height.
            segment.layer.cornerRadius = ProductCreationHeaderLayout.progressHeight / 2
            segment.layer.maskedCorners = index == 0
                ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                : index == 3 ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            segment.clipsToBounds = true
            addSubview(segment)
        }
        configure(stage: stage)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(stage: ProductCreationStage) {
        for (index, segment) in segments.enumerated() {
            segment.backgroundColor = UIColor(named: index < stage.rawValue ? "BrandMain500" : "BrandNeutral200")
        }
        accessibilityValue = "4단계 중 \(stage.rawValue)단계, \(stage.title)"
        accessibilityIdentifier = stage == .measurementResult ? "garmentResultProgress" : "product-flow.progress"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = ProductCreationHeaderLayout.segmentSpacing
        let width = max(0, (bounds.width - gap * 3) / 4)
        for (index, segment) in segments.enumerated() {
            segment.frame = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: ProductCreationHeaderLayout.progressHeight)
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: ProductCreationHeaderLayout.progressHeight) }
}

extension View {
    /// Reserves the design's 16pt header area above the native navigation bar.
    func productCreationProgress(_ stage: ProductCreationStage?) -> some View {
        background { ProductCreationProgressPresenter(stage: stage) }
    }
}

private struct ProductCreationProgressPresenter: UIViewControllerRepresentable {
    let stage: ProductCreationStage?
    @Environment(\.measurementCaptureChromeOpacity) private var chromeOpacity
    @Environment(\.measurementCaptureCover) private var captureCover

    func makeUIViewController(context: Context) -> Presenter { Presenter() }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
        presenter.stage = stage
        presenter.progressOpacity = chromeOpacity
        presenter.captureCover = captureCover
        presenter.updateProgress()
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: ()) {
        presenter.restore()
    }

    final class Presenter: UIViewController {
        var stage: ProductCreationStage?
        var progressOpacity: Double = 1
        var captureCover: MeasurementCaptureCover?
        let bar = ProductCreationProgressBar(stage: .measurement)
        private let coverMask = CALayer()
        private var isVisible = false
        private weak var insetNavigation: UINavigationController?
        private var originalInsets: UIEdgeInsets?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            updateProgress()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateProgress()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            restore()
        }

        func restore() {
            bar.layer.mask = nil
            bar.removeFromSuperview()
            if let originalInsets { insetNavigation?.additionalSafeAreaInsets = originalInsets }
            insetNavigation = nil
            originalInsets = nil
        }

        func updateProgress() {
            guard isVisible, let stage, let navigation = navigationController,
                  let window = navigation.view.window else {
                restore()
                return
            }
            if insetNavigation !== navigation {
                restore()
                insetNavigation = navigation
                originalInsets = navigation.additionalSafeAreaInsets
                navigation.additionalSafeAreaInsets.top += ProductCreationHeaderLayout.navigationInset
            }
            bar.configure(stage: stage)
            // The native bar sits above SwiftUI's Home cover. Match its full
            // held opacity too, including corners outside a fitted smaller reel.
            let opacity = progressOpacity.isFinite ? min(1, max(0, progressOpacity)) : 1
            let reveal = captureCover.map {
                $0.revealOpacity.isFinite ? min(1, max(0, $0.revealOpacity)) : 0
            } ?? 1
            bar.alpha = CGFloat(opacity * reveal)
            bar.isHidden = opacity * reveal <= 0
            if bar.superview !== navigation.view { navigation.view.addSubview(bar) }
            navigation.view.bringSubviewToFront(bar)
            let top = navigation.view.convert(CGPoint(x: 0, y: window.safeAreaInsets.top), from: window).y
            bar.frame = CGRect(x: 0, y: top, width: navigation.view.bounds.width, height: ProductCreationHeaderLayout.progressHeight)
            updateCoverMask(in: window)
        }

        private func updateCoverMask(in window: UIWindow) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard let captureCover, captureCover.diameter.isFinite, captureCover.diameter > 0,
                  captureCover.center.x.isFinite, captureCover.center.y.isFinite,
                  bar.bounds.width > 0, bar.bounds.height > 0 else {
                bar.layer.mask = nil
                return
            }

            // The progress bar is attached directly to the native navigation
            // controller. Mirror the Home cover here so its high layer order
            // cannot paint a registration segment through the moving reel.
            let frame = window.convert(bar.bounds, from: bar)
            let radius = captureCover.diameter / 2
            let circle = CGRect(x: captureCover.center.x - radius - frame.minX,
                y: captureCover.center.y - radius - frame.minY,
                width: captureCover.diameter, height: captureCover.diameter)
            let lowerTop = min(bar.bounds.height, max(0, captureCover.center.y - frame.minY))
            guard circle.intersects(bar.bounds) || lowerTop < bar.bounds.height else {
                bar.layer.mask = nil
                return
            }

            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: bar.bounds.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(bar.bounds)
                context.cgContext.setBlendMode(.clear)
                context.cgContext.fillEllipse(in: circle)
                context.cgContext.fill(CGRect(x: 0, y: lowerTop,
                    width: bar.bounds.width, height: bar.bounds.height - lowerTop))
            }
            coverMask.frame = bar.bounds
            coverMask.contentsScale = format.scale
            coverMask.contents = image.cgImage
            bar.layer.mask = coverMask
        }
    }
}
