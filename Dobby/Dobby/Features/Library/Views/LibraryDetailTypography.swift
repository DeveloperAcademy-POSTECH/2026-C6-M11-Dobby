import SwiftUI

/// Figma 5203:8275 uses the registered Pretendard assets and native SF Pro.
/// Keep the actual text-node fonts; the design's token names can say "Italic"
/// even though the selected font is Pretendard SemiBold.
enum LibraryDetailTypography {
    static let heading: Font = .system(size: 17, weight: .semibold)
    static let body: Font = .system(size: 14, weight: .regular)
    static let edit: Font = .system(size: 17, weight: .medium)
    static let photoAndMeasurementHeading: Font = .custom("Pretendard-SemiBold", size: 17, relativeTo: .headline)
    static let measurementValue: Font = .custom("Pretendard-Regular", size: 15, relativeTo: .subheadline)
    static let upload: Font = .custom("Pretendard-SemiBold", size: 16, relativeTo: .callout)
}
