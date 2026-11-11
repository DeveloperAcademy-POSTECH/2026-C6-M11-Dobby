import Foundation

/// A virtual center is supported by two observed front-opening edges. It stays
/// at their midpoint, even outside the silhouette; the garment plane provides
/// its 3D position. No background depth or mask dilation is used.
nonisolated enum OuterwearCenterGapPolicy {
    static func accepted(response: OuterwearLandmarkResponse, mask: GarmentMask) -> Set<String> {
        guard response.allowsCenterEstimates, response.view == .front,
              mask.size.isValid, mask.values.count == mask.size.width * mask.size.height,
              let left = response.points["armpit_left"]?.point,
              let right = response.points["armpit_right"]?.point, right.x > left.x else { return [] }
        let w = mask.size.width, h = mask.size.height
        func nearMaterial(_ p: ImagePoint) -> Bool {
            guard p.isValid else { return false }
            let x = Int(p.x * Double(w)), y = Int(p.y * Double(h))
            // Boundary observations and segmentation can differ by two mask
            // pixels. This tests support only; neither coordinate is moved.
            for dy in -2...2 {
                for dx in -2...2 where dx * dx + dy * dy <= 4 {
                    let cx = x + dx, cy = y + dy
                    if cx >= 0, cy >= 0, cx < w, cy < h, mask.values[cy * w + cx] == 1 { return true }
                }
            }
            return false
        }
        let shoulders = ["shoulder_left", "shoulder_right"].compactMap { response.points[$0]?.point }
        let hems = ["hem_left", "hem_right"].compactMap { response.points[$0]?.point }.filter(nearMaterial)
        guard nearMaterial(left), nearMaterial(right), let top = shoulders.map(\.y).min(),
              let bottom = hems.map(\.y).max(), bottom > top else { return [] }
        let width = right.x - left.x, height = bottom - top
        var accepted = Set<String>()
        for (id, observation, support) in [
            ("top_length_start", response.frontNeckSeamCenter, response.centerSupport?.frontNeckSeamCenter),
            ("hem_center", response.points["hem_center"], response.centerSupport?.hemCenter)
        ] {
            guard observation?.visibility == .estimated, let support,
                  nearMaterial(support.left), nearMaterial(support.right),
                  support.right.x - support.left.x <= width * 0.20 + 1e-9,
                  abs(support.right.y - support.left.y) <= height * 0.06 + 1e-9 else { continue }
            let center = support.midpoint
            guard (0.3...0.7).contains((center.x - left.x) / width) else { continue }
            if id == "hem_center" {
                guard center.y > max(left.y, right.y) else { continue }
                // Both supporting ends must be near an actual finishing edge,
                // not points on a pocket, zipper slider or interior seam.
                let rows = max(3, Int(ceil(height * Double(h) * 0.04)))
                guard [support.left, support.right].allSatisfy({ p in
                    let x = Int(p.x * Double(w)), y = Int(p.y * Double(h))
                    return (1...rows).contains { delta in
                        let row = y + delta
                        return row < h && mask.values[row * w + x] == 0
                    }
                }) else { continue }
            } else {
                guard center.y >= top - height * 0.15, center.y < min(left.y, right.y) else { continue }
            }
            accepted.insert(id)
        }
        return accepted
    }
}

nonisolated struct GarmentCenterEstimate: Codable, Sendable {
    var landmarkID: String
    var point: ImagePoint
    var leftSupport: ImagePoint
    var rightSupport: ImagePoint
}
