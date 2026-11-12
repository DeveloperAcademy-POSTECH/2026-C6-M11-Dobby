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
         usesSheet: Bool? = nil, sheetHeight: CGFloat? = nil) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let safeBottom = max(0, bottomSafeArea)
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 3 / 4
        let summaryHeight = max(111, summaryHeight)
        expandedSheetHeight = 28 + summaryHeight + safeBottom + 16
        collapsedSheetHeight = safeBottom + 25

        if usesSheet ?? Self.usesSheet(aspect: aspect) {
            // 402×874 reference: the canvas starts below the status bar;
            // the 16:9 photograph begins at screen y=158 and extends to y=874.
            let top: CGFloat = 96
            let photoHeight = min(width / aspect, max(1, height - top))
            let photoWidth = min(width, photoHeight * aspect)
            photo = CGRect(x: (width - photoWidth) / 2, y: top, width: photoWidth, height: photoHeight)
            let visibleSheetHeight = min(height, max(collapsedSheetHeight, sheetHeight ?? expandedSheetHeight))
            let topOfSheet = height - visibleSheetHeight
            sheetTop = topOfSheet
            summary = CGRect(x: 19, y: topOfSheet + 28, width: max(1, width - 38), height: summaryHeight)
        } else {
            sheetTop = nil
            let summaryTop = height - safeBottom - 15 - summaryHeight
            summary = CGRect(x: 20.5, y: max(0, summaryTop), width: max(1, width - 41), height: summaryHeight)
            // Fit in the reference 4:3 window; a square photo is centred within
            // it with the designer's 6pt optical adjustment. No extra crop.
            let top = ProductCreationHeaderLayout.photoTop
            let windowHeight = max(1, summary.minY - 32 - top)
            let photoHeight = min(width / aspect, windowHeight)
            let photoWidth = min(width, photoHeight * aspect)
            let squareAdjustment: CGFloat = abs(aspect - 1) < 0.02 ? min(6, max(0, windowHeight - photoHeight) / 2) : 0
            photo = CGRect(x: (width - photoWidth) / 2,
                           y: top + max(0, windowHeight - photoHeight) / 2 + squareAdjustment,
                           width: photoWidth, height: photoHeight)
        }
    }
}
