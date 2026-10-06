import Foundation

/// Select one physical side for presentation without changing the measurements
/// or landmarks retained for recalculation and saved evidence.
nonisolated enum GarmentMeasurementPresentation {
    /// Result-photo overlays use the shop's current measurement list. Filter
    /// known omissions instead of assuming a fixed count, so future hip/thigh
    /// definitions can join without changing the editor or losing raw records.
    private static let hiddenOverlayIDs: Set<String> = [
        "top.hemWidth", "top.sleeveLengthRight",
        "bottom.hem_right_outer.waist_right", "bottom.hem_right_inner.hem_right_outer",
        "bottom.crotch.hem_left_inner", "bottom.crotch.hem_right_inner"
    ]

    static func overlayMeasurements<Element>(_ measurements: [Element], id: (Element) -> String) -> [Element] {
        measurements.filter { !hiddenOverlayIDs.contains(id($0)) }
    }

    static func overlayTitle(for id: String, fallback: String) -> String {
        switch id {
        case "top.shoulderWidth": "어깨"
        case "top.chestWidth": "가슴"
        case "top.sleeveLengthLeft": "소매"
        case "top.totalLength": "총장"
        case "bottom.waist_left.waist_right": "허리"
        case "bottom.crotch.waist_center": "밑위"
        case "bottom.hem_left_outer.waist_left": "총장"
        case "bottom.hem_left_inner.hem_left_outer": "밑단"
        default: fallback
        }
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
