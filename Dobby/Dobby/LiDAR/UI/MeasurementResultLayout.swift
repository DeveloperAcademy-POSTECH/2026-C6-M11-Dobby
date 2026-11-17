import CoreGraphics

/// Layout is presentation-only. Changing the sheet never resizes the photo or
/// changes the captured image/depth coordinate system underneath the editor.
nonisolated struct MeasurementResultLayout {
    let photo: CGRect
    let summary: CGRect
    let sheetTop: CGFloat?
    let expandedSheetHeight: CGFloat
    let collapsedSheetHeight: CGFloat

    var magnifierBottomInset: CGFloat {
        guard let sheetTop else { return 0 }
        return min(photo.height, max(0, photo.maxY - sheetTop))
    }

    static func usesSheet(aspect: CGFloat) -> Bool { aspect.isFinite && aspect > 0 && aspect < 0.67 }

    init(size: CGSize, bottomSafeArea: CGFloat, aspect: CGFloat, summaryHeight: CGFloat,
         captureAspect: CGFloat? = nil, topSafeArea: CGFloat = 0,
         usesSheet: Bool? = nil, sheetHeight: CGFloat? = nil) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let safeBottom = max(0, bottomSafeArea)
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 3 / 4
        let summaryHeight = max(111, summaryHeight)
        expandedSheetHeight = 28 + summaryHeight + safeBottom + 16
        collapsedSheetHeight = safeBottom + 25

        if usesSheet ?? Self.usesSheet(aspect: aspect) {
            let top = ProductCreationLayoutMetrics.headerHeight + ProductCreationLayoutMetrics.photoGap
            let photoHeight = min(width / aspect, max(1, height - top))
            let photoWidth = min(width, photoHeight * aspect)
            photo = CGRect(x: (width - photoWidth) / 2, y: top, width: photoWidth, height: photoHeight)
            let visibleSheetHeight = min(height, max(collapsedSheetHeight, sheetHeight ?? expandedSheetHeight))
            let topOfSheet = height - visibleSheetHeight
            sheetTop = topOfSheet
            summary = CGRect(x: 19, y: topOfSheet + 28, width: max(1, width - 38), height: summaryHeight)
        } else {
            sheetTop = nil
            // Use the selected capture ratio for the screen composition. The
            // editor may retain a larger crop to keep every measurement handle.
            let capturedAspect = captureAspect ?? aspect
            let isSquare = capturedAspect.isFinite && abs(capturedAspect - 1) < 0.000_001
            let summaryTop = height - safeBottom - 15 - summaryHeight
            let summaryInset: CGFloat = isSquare ? 19 : 20.5
            summary = CGRect(x: summaryInset, y: max(0, summaryTop),
                             width: max(1, width - summaryInset * 2), height: summaryHeight)
            let top = ProductCreationLayoutMetrics.headerHeight + ProductCreationLayoutMetrics.photoGap
            let windowHeight = max(1, summary.minY - 33 - top)
            let photoAspect: CGFloat = isSquare ? 1 : aspect
            let photoHeight = min(width / photoAspect, windowHeight)
            let photoWidth = min(width, photoHeight * photoAspect)
            // Figma 5254:6854: 402×402 at screen y=218 in a 402×874
            // window. Its centre is 18pt above the window centre. Include the
            // status area in that calculation, then return local coordinates.
            let safeTop = topSafeArea.isFinite ? max(0, topSafeArea) : 0
            let centeredTop = (height + safeTop - photoHeight) / 2 - 18 - safeTop
            let photoTop = isSquare
                ? min(max(top, centeredTop), max(top, summary.minY - 33 - photoHeight))
                : top
            photo = CGRect(x: (width - photoWidth) / 2,
                           y: photoTop,
                           width: photoWidth, height: photoHeight)
        }
    }
}
