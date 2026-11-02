import Foundation

/// Exact source identities select the calculation contract; an arbitrary model
/// name must never opt into a different measurement or archive interpretation.
nonisolated enum GarmentLandmarkModelContract {
    static let lunaOuterwearVersion = "luna-outerwear11-backseam-v1"
    static let lunaViewLengthVersion = "luna-outerwear11-view-length-v2"
    static let lunaFrontLengthVersion = "luna-outerwear11-front-length-v3"
    static let lunaGapLengthVersion = "luna-outerwear11-front-gap-v4"
    static let frontGapConvention = "center-front-neck-to-hem-small-gap-midpoint-v1"
    static let backNeckSeamConvention = "center-back-neck-body-seam-to-back-hem-v1"
    static let frontNeckSeamConvention = "center-front-neck-body-seam-to-front-hem-v1"

    static func isLunaOuterwear(version: String?, kind: AutomaticGarmentKind) -> Bool {
        kind == .top && [lunaOuterwearVersion, lunaViewLengthVersion, lunaFrontLengthVersion, lunaGapLengthVersion].contains(version ?? "")
    }

    static func isFrontLengthOuterwear(version: String?, kind: AutomaticGarmentKind) -> Bool {
        kind == .top && [lunaFrontLengthVersion, lunaGapLengthVersion].contains(version ?? "")
    }

    static func isViewLengthOuterwear(version: String?, kind: AutomaticGarmentKind) -> Bool {
        kind == .top && version == lunaViewLengthVersion
    }

    static func isCurrent(version: String?, kind: AutomaticGarmentKind) -> Bool {
        version == kind.modelVersion || isLunaOuterwear(version: version, kind: kind)
    }
}
