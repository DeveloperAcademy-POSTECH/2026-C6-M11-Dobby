import Foundation

/// A presentation-only choice. The original RGB/depth pair, calibration and
/// raw landmark coordinates remain authoritative for measurement.
nonisolated enum MeasurementPhotoAspectRatio: String, CaseIterable, Sendable {
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case square = "1:1"

    /// Nominal width / height in the displayed orientation. The default mode
    /// preserves the actual source ratio when it is not the native 4:3 raster;
    /// consumers should use that source ratio to lay out its uncropped window.
    func displayRatio(isLandscape: Bool) -> Double {
        switch self {
        case .fourThree: isLandscape ? 4.0 / 3 : 3.0 / 4
        case .sixteenNine: isLandscape ? 16.0 / 9 : 9.0 / 16
        case .square: 1
        }
    }

    /// A centered region in oriented normalized coordinates. Default 4:3 keeps
    /// #101's full-sensor framing, including legacy non-4:3 test/import rasters.
    /// Other choices crop exactly once after any registered 2x RGB/depth crop.
    func displayCrop(imageSize: PixelSize, orientation: ImageOrientation) -> PhotoDisplayCrop? {
        guard imageSize.isValid else { return nil }
        if self == .fourThree { return .full }
        let quarterTurn = orientation == .left || orientation == .right
        let width = quarterTurn ? imageSize.height : imageSize.width
        let height = quarterTurn ? imageSize.width : imageSize.height
        // Infer direction from the actual oriented raster, rather than assuming
        // .up is always landscape: synthetic/imported images may be portrait.
        // A square source is neutral and uses the portrait 9:16 convention.
        let aspect = displayRatio(isLandscape: width > height)
        return PhotoDisplayCrop.matchingPreview(imageSize: imageSize, orientation: orientation,
            viewportWidth: aspect, viewportHeight: 1,
            visibleRect: .init(x: 0, y: 0, width: 1, height: 1))
    }
}

extension CaptureSnapshot {
    /// An informational presentation change, never a measurement failure.
    /// Missing legacy metadata or invalid imported rectangles cannot imply that
    /// the user selected a different framing. Ignore floating-point noise.
    var hasExpandedPhotoPresentation: Bool {
        guard let selected = capturePresentationCrop, selected.isValid,
              let displayed = presentationCrop, displayed.isValid else { return false }
        let tolerance = 1e-6
        return abs(displayed.x - selected.x) > tolerance
            || abs(displayed.y - selected.y) > tolerance
            || abs(displayed.width - selected.width) > tolerance
            || abs(displayed.height - selected.height) > tolerance
    }
}
