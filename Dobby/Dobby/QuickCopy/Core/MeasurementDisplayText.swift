import Foundation

/// Whole-centimeter presentation only; stored and copied values keep their precision.
nonisolated enum MeasurementDisplayText {
    static func centimeters(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded != 0 else { return "0" }
        return rounded.formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
            .grouping(.never).precision(.fractionLength(0)))
    }

    static func centimeters(_ text: String) -> String {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")), value.isFinite else { return text }
        return centimeters(value)
    }
}
