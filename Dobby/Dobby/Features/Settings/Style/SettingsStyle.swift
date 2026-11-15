import SwiftUI

enum SettingsStyle {
    static let background = Color("BrandNeutral50")
    static let surface = Color("BrandNeutralWhite")
    static let primaryText = Color("BrandNeutralBlack")
    static let secondaryText = Color("BrandNeutral500")
    static let buttonText = Color("BrandNeutral950")
    static let separator = Color("BrandNeutral200")
    static let destructive = Color("AccentsRed")
}

enum SettingsTypography {
    static let screenTitle = Font.custom("Pretendard-Bold", fixedSize: 24)
    static let sectionTitle = Font.custom("Pretendard-Bold", fixedSize: 20)
    static let labelMedium = Font.custom("Pretendard-Medium", fixedSize: 16)
    static let labelSmall = Font.custom("Pretendard-Medium", fixedSize: 14)

    static let screenTitleTracking: CGFloat = -0.24
    static let sectionTitleTracking: CGFloat = -0.20
    static let labelMediumTracking: CGFloat = -0.16
    static let labelSmallTracking: CGFloat = -0.14
}
