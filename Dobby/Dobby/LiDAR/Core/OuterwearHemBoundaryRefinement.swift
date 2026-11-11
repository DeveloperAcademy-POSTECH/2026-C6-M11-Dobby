import Foundation

/// Refine a visible AI center-hem candidate only along its own body column.
/// This does not fill nulls or choose the nearest arbitrary silhouette point.
nonisolated enum OuterwearHemBoundaryRefinement {
    static let method = "outerwear-hem-column-boundary-2_5pct-v1"

    /// Called only after single-garment association and layout validation.
    /// Input/output coordinates are full upright normalized coordinates.
    static func correction(response: OuterwearLandmarkResponse, mask: GarmentMask)
        -> (point: ImagePoint, limitHeightFraction: Double)? {
        guard response.isFrontOnly, response.view == .front,
              let hem = response.points["hem_center"]?.point,
              mask.size.isValid, mask.values.count == mask.size.width * mask.size.height else { return nil }
        let w = mask.size.width, h = mask.size.height
        func material(_ p: ImagePoint) -> Bool {
            p.isValid && mask.values[Int(p.y * Double(h)) * w + Int(p.x * Double(w))] == 1
        }
        guard !material(hem),
              let left = response.points["armpit_left"]?.point,
              let right = response.points["armpit_right"]?.point,
              material(left), material(right), right.x > left.x else { return nil }
        // A center hem must be in the middle part of the observed body, below
        // both armpits and close in height to at least one supported side hem.
        let bodyWidth = right.x - left.x
        let fraction = (hem.x - left.x) / bodyWidth
        let bodyTop = max(left.y, right.y)
        let sideHems = ["hem_left", "hem_right"].compactMap { response.points[$0]?.point }.filter(material)
        guard (0.3...0.7).contains(fraction), hem.y > bodyTop,
              let bounds = try? OuterwearComparisonGeometry.garmentBounds(mask: mask),
              sideHems.contains(where: { abs($0.y - hem.y) <= bounds.height * 0.06 }) else { return nil }
        let limit = bounds.height * 0.025 * Double(h)
        let x = Int(hem.x * Double(w)), startY = Int(ceil(bodyTop * Double(h))) + 1
        let radius = max(2, Int(ceil(bodyWidth * Double(w) * 0.02)))
        guard x - radius >= 0, x + radius < w, startY >= 0, startY < h else { return nil }
        var exits: [Int] = []
        for column in (x - radius)...(x + radius) {
            guard mask.values[startY * w + column] == 1 else { return nil }
            var row = startY
            // Follow continuous body material, stopping at its FIRST exit.
            // An open front, hole or intervening background is not bridged.
            while row < h, mask.values[row * w + column] == 1 { row += 1 }
            guard row + 2 < h,
                  (row...(row + 2)).allSatisfy({ mask.values[$0 * w + column] == 0 }),
                  abs(Double(row) - hem.y * Double(h)) <= limit else { return nil }
            exits.append(row)
        }
        // A jagged notch/isolated foreground is not a supported center boundary.
        guard let minY = exits.min(), let maxY = exits.max(), maxY - minY <= 2 else { return nil }
        let correctedY = (Double(exits[radius]) - 0.5) / Double(h)
        guard abs(correctedY - hem.y) * Double(h) <= limit else { return nil }
        return (.init(x: hem.x, y: correctedY), bounds.height * 0.025)
    }
}
