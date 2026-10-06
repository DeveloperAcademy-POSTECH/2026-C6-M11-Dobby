import CoreGraphics
import Foundation

extension GarmentPhotoGeometry {
    /// Centre the capsule on its measurement line, sliding along that same line
    /// only when the midpoint is obstructed. A nearby callout is the fallback;
    /// the visible capsule must never cover a physical marker or another control.
    static func overlaySegmentLabelPlacement(start: CGPoint, end: CGPoint, labelSize: CGSize,
        imageSize: CGSize, occupied: [CGRect], markers: [CGRect] = []) -> SegmentLabelPlacement? {
        guard [start.x, start.y, end.x, end.y, labelSize.width, labelSize.height,
               imageSize.width, imageSize.height].allSatisfy(\.isFinite),
              labelSize.width > 0, labelSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }

        let ordered = start.x < end.x || (start.x == end.x && start.y <= end.y)
        let a = ordered ? start : end, b = ordered ? end : start
        let delta = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let length = hypot(delta.x, delta.y)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        guard [delta.x, delta.y, length, middle.x, middle.y].allSatisfy(\.isFinite) else { return nil }
        let touchSize = CGSize(width: labelSize.width, height: max(44, labelSize.height))
        let bounds = CGRect(origin: .zero, size: imageSize).insetBy(dx: 4, dy: 4)
        guard bounds.width >= touchSize.width, bounds.height >= touchSize.height else { return nil }

        func isFiniteRect(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
                && !rect.isNull && rect.width >= 0 && rect.height >= 0
        }
        let controls = occupied.filter(isFiniteRect)
        // Callers also pass all visible markers, including a selected marker's
        // halo. Always protect both endpoints even if that list is incomplete.
        let endpoints = [a, b].map {
            CGRect(x: $0.x - 9, y: $0.y - 9, width: 18, height: 18)
        }
        let physicalMarkers = markers.filter(isFiniteRect) + endpoints

        func touchRect(at center: CGPoint) -> CGRect {
            CGRect(x: center.x - touchSize.width / 2, y: center.y - touchSize.height / 2,
                   width: touchSize.width, height: touchSize.height)
        }
        func clear(_ rect: CGRect) -> Bool {
            let visible = CGRect(x: rect.minX, y: rect.midY - labelSize.height / 2,
                                 width: labelSize.width, height: labelSize.height)
            return bounds.contains(rect)
                && !controls.contains { $0.insetBy(dx: -3, dy: -3).intersects(rect) }
                && !physicalMarkers.contains { $0.insetBy(dx: -3, dy: -3).intersects(visible) }
        }

        // A rectangle's extent along a diagonal is wider than its height. Keep
        // the whole visible label between endpoints with room for their dots.
        let halfSpan = length > 0
            ? (abs(delta.x) * labelSize.width + abs(delta.y) * labelSize.height) / (2 * length) : 0
        if length >= halfSpan * 2 + 26 {
            let margin = (halfSpan + 13) / length
            let centreBounds = CGRect(x: bounds.minX + touchSize.width / 2,
                y: bounds.minY + touchSize.height / 2,
                width: bounds.width - touchSize.width, height: bounds.height - touchSize.height)
            if let inBounds = overlayLineInterval(start: a, delta: delta, inside: centreBounds) {
                let lower = max(margin, inBounds.lower), upper = min(1 - margin, inBounds.upper)
                if lower <= upper {
                    var intervals = [(lower: lower, upper: upper)]
                    let blockers = controls.map {
                        $0.insetBy(dx: -(touchSize.width / 2 + 4), dy: -(touchSize.height / 2 + 4))
                    } + physicalMarkers.map {
                        $0.insetBy(dx: -(labelSize.width / 2 + 4), dy: -(labelSize.height / 2 + 4))
                    }
                    // Subtract blocked spans analytically. This can find narrow
                    // clear gaps without arbitrary pixel/fraction sampling.
                    for blocker in blockers {
                        guard let blocked = overlayLineInterval(start: a, delta: delta, inside: blocker) else { continue }
                        intervals = intervals.flatMap { interval -> [(lower: CGFloat, upper: CGFloat)] in
                            if blocked.upper < interval.lower || blocked.lower > interval.upper { return [interval] }
                            var remaining: [(lower: CGFloat, upper: CGFloat)] = []
                            if blocked.lower > interval.lower {
                                remaining.append((interval.lower, min(interval.upper, blocked.lower)))
                            }
                            if blocked.upper < interval.upper {
                                remaining.append((max(interval.lower, blocked.upper), interval.upper))
                            }
                            return remaining
                        }
                    }
                    let candidates = intervals.map { min(max(0.5, $0.lower), $0.upper) }.sorted {
                        let lhs = abs($0 - 0.5), rhs = abs($1 - 0.5)
                        return lhs == rhs ? $0 < $1 : lhs < rhs
                    }
                    for fraction in candidates {
                        let rect = touchRect(at: .init(x: a.x + delta.x * fraction, y: a.y + delta.y * fraction))
                        if clear(rect) { return .init(rect: rect, isCallout: false) }
                    }
                }
            }
        }
        return labelPlacement(near: middle, labelSize: touchSize, imageSize: imageSize,
            occupied: controls, markers: physicalMarkers, visibleLabelHeight: labelSize.height)
            .map { .init(rect: $0, isCallout: true) }
    }

    /// Fractions of the line lying inside an axis-aligned centre/obstacle box.
    private static func overlayLineInterval(start: CGPoint, delta: CGPoint, inside rect: CGRect)
        -> (lower: CGFloat, upper: CGFloat)? {
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (origin, direction, minimum, maximum) in [
            (start.x, delta.x, rect.minX, rect.maxX),
            (start.y, delta.y, rect.minY, rect.maxY)
        ] {
            if abs(direction) < 1e-12 {
                guard origin >= minimum && origin <= maximum else { return nil }
            } else {
                let first = (minimum - origin) / direction, last = (maximum - origin) / direction
                lower = max(lower, min(first, last))
                upper = min(upper, max(first, last))
                guard lower <= upper else { return nil }
            }
        }
        return (lower, upper)
    }
}
