import Foundation

/// Select one physical side for presentation without changing the measurements
/// or landmarks retained for recalculation and saved evidence.
nonisolated enum GarmentMeasurementPresentation {
    struct Column {
        let measurementID: String
        let productKey: String
        let title: String
    }

    static let topColumns: [Column] = [
        .init(measurementID: "top.totalLength", productKey: "totalLength", title: "총장"),
        .init(measurementID: "top.shoulderWidth", productKey: "shoulderWidth", title: "어깨"),
        .init(measurementID: "top.chestWidth", productKey: "chestWidth", title: "가슴"),
        .init(measurementID: "top.sleeveLengthLeft", productKey: "sleeveLengthLeft", title: "소매")
    ]
    static let bottomColumns: [Column] = [
        .init(measurementID: "bottom.hem_left_outer.waist_left", productKey: "totalLengthLeft", title: "총장"),
        .init(measurementID: "bottom.waist_left.waist_right", productKey: "waistWidth", title: "허리"),
        .init(measurementID: "bottom.crotch.waist_front_center", productKey: "frontRise", title: "밑위"),
        .init(measurementID: "bottom.thighWidthRight", productKey: "thighWidthRight", title: "허벅지"),
        .init(measurementID: "bottom.hem_left_inner.hem_left_outer", productKey: "hemWidthLeft", title: "밑단")
    ]

    static func productMeasurements<Element>(_ measurements: [Element], isTop: Bool,
                                             key: (Element) -> String) -> [Element] {
        (isTop ? topColumns : bottomColumns).compactMap { column in
            measurements.first { key($0) == column.productKey }
        }
    }

    static func productTitle(for key: String, fallback: String) -> String {
        (topColumns + bottomColumns).first { $0.productKey == key }?.title ?? fallback
    }

    /// Result-photo overlays use the shop's current measurement list. Filter
    /// known omissions instead of assuming a fixed count, so future hip/thigh
    /// definitions can join without changing the editor or losing raw records.
    private static let hiddenOverlayIDs: Set<String> = [
        "top.hemWidth", "top.sleeveLengthRight",
        "bottom.hem_right_outer.waist_right", "bottom.hem_right_inner.hem_right_outer",
        "bottom.crotch.hem_left_inner", "bottom.crotch.hem_right_inner"
    ]

    static func overlayMeasurements<Element>(_ measurements: [Element], id: (Element) -> String) -> [Element] {
        let columns = topColumns + bottomColumns
        return measurements.enumerated().filter { !hiddenOverlayIDs.contains(id($0.element)) }
            .sorted { left, right in
                let a = columns.firstIndex { $0.measurementID == canonicalID(id(left.element)) } ?? columns.count
                let b = columns.firstIndex { $0.measurementID == canonicalID(id(right.element)) } ?? columns.count
                return a == b ? left.offset < right.offset : a < b
            }.map(\.element)
    }

    static func overlayTitle(for id: String, fallback: String) -> String {
        (topColumns + bottomColumns).first { $0.measurementID == canonicalID(id) }?.title ?? fallback
    }

    /// Old bottom7 records retain their ID but occupy the same visible rise row.
    static func canonicalID(_ id: String) -> String {
        id == "bottom.crotch.waist_center" ? "bottom.crotch.waist_front_center" : id
    }

    static func isVisibleMeasurementID(_ id: String, kind: AutomaticGarmentKind) -> Bool {
        (kind == .top ? topColumns : bottomColumns).contains { $0.measurementID == canonicalID(id) }
    }

    private struct Pair {
        let left: String
        let right: String
        let title: String
        let shortTitle: String
    }

    private static let pairs: [Pair] = [
        .init(left: "top.sleeveLengthLeft", right: "top.sleeveLengthRight",
              title: "소매길이(직선)", shortTitle: "소매"),
        .init(left: "bottom.hem_left_outer.waist_left", right: "bottom.hem_right_outer.waist_right",
              title: "총장(직선)", shortTitle: "총장"),
        .init(left: "bottom.hem_left_inner.hem_left_outer", right: "bottom.hem_right_inner.hem_right_outer",
              title: "밑단 단면", shortTitle: "밑단"),
        .init(left: "bottom.crotch.hem_left_inner", right: "bottom.crotch.hem_right_inner",
              title: "인심(직선)", shortTitle: "인심"),
        .init(left: "sleeveLengthLeft", right: "sleeveLengthRight",
              title: "소매길이", shortTitle: "소매"),
        .init(left: "totalLengthLeft", right: "totalLengthRight",
              title: "총장", shortTitle: "총장"),
        .init(left: "hemWidthLeft", right: "hemWidthRight",
              title: "밑단 단면", shortTitle: "밑단"),
        .init(left: "inseamLeft", right: "inseamRight",
              title: "인심(직선)", shortTitle: "인심"),
        .init(left: "thighWidthLeft", right: "thighWidthRight",
              title: "허벅지 단면", shortTitle: "허벅지")
    ]

    /// Prefer a usable left measurement, then the right. If neither is usable,
    /// keep one existing row so its failure can still be reviewed and corrected.
    /// Unknown items and their relative order are preserved. Never average sides.
    static func visibleMeasurements<Element>(_ measurements: [Element],
        id: (Element) -> String, isUsable: (Element) -> Bool) -> [Element] {
        var hiddenIDs = Set<String>()
        for pair in pairs {
            let left = measurements.first { id($0) == pair.left }
            let right = measurements.first { id($0) == pair.right }
            let selected = left.flatMap { isUsable($0) ? $0 : nil }
                ?? right.flatMap { isUsable($0) ? $0 : nil } ?? left ?? right
            guard let selected else { continue }
            hiddenIDs.insert(id(selected) == pair.left ? pair.right : pair.left)
        }
        return measurements.filter { !hiddenIDs.contains(id($0)) }
    }

    static func title(for id: String, fallback: String) -> String {
        pair(for: id)?.title ?? fallback
    }

    static func shortTitle(for id: String, fallback: String) -> String {
        pair(for: id)?.shortTitle ?? fallback
    }

    private static func pair(for id: String) -> Pair? {
        pairs.first { $0.left == id || $0.right == id }
    }
}
