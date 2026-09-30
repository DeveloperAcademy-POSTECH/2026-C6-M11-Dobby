import Foundation

/// Exact pixel-union boundaries in the full, unrotated RGB image's coordinate system.
/// Apply the image-to-display transform when drawing; close every returned contour
/// and use an even-odd fill to preserve holes and separated garment regions.
nonisolated enum GarmentSilhouetteGeometry {
    static let maximumMaskDimension = 512
    static let maximumContourVertices = 65_536

    /// Returns nil for malformed or excessively complex masks, and [] for an empty mask.
    /// Each closed contour omits its repeated closing point. Coordinates describe pixel
    /// edges, so the right and bottom image boundaries can equal 1 (unlike point samples).
    static func contours(from mask: GarmentMask) -> [[ImagePoint]]? {
        let width = mask.size.width, height = mask.size.height
        guard width > 0, height > 0,
              width <= maximumMaskDimension, height <= maximumMaskDimension,
              mask.values.count == width * height,
              mask.values.allSatisfy({ $0 <= 1 }) else { return nil }
        guard mask.values.contains(1) else { return [] }

        // Directed edges keep foreground on the right in image coordinates. Four bits
        // per grid vertex avoid a dictionary/edge object for every boundary pixel.
        let stride = width + 1
        var outgoing = [UInt8](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            for x in 0..<width where mask.values[y * width + x] == 1 {
                let vertex = y * stride + x
                if y == 0 || mask.values[(y - 1) * width + x] == 0 {
                    outgoing[vertex] |= 1 // East.
                }
                if x == width - 1 || mask.values[y * width + x + 1] == 0 {
                    outgoing[vertex + 1] |= 2 // South.
                }
                if y == height - 1 || mask.values[(y + 1) * width + x] == 0 {
                    outgoing[vertex + stride + 1] |= 4 // West.
                }
                if x == 0 || mask.values[y * width + x - 1] == 0 {
                    outgoing[vertex + stride] |= 8 // North.
                }
            }
        }

        var contours: [[ImagePoint]] = []
        var vertexCount = 0
        let offsets = [1, stride, -1, -stride]
        for start in outgoing.indices {
            while outgoing[start] != 0 {
                let firstDirection = outgoing[start].trailingZeroBitCount
                var direction = firstDirection
                var current = start
                var corners = [start]
                while true {
                    outgoing[current] &= ~(UInt8(1) << direction)
                    current += offsets[direction]
                    if current == start { break }

                    let available = outgoing[current]
                    // At a diagonal contact, turn right to keep the two pixel regions
                    // separate instead of making a self-touching figure-eight contour.
                    let right = (direction + 1) & 3
                    let left = (direction + 3) & 3
                    let back = (direction + 2) & 3
                    let next: Int
                    if available & (UInt8(1) << right) != 0 { next = right }
                    else if available & (UInt8(1) << direction) != 0 { next = direction }
                    else if available & (UInt8(1) << left) != 0 { next = left }
                    else if available & (UInt8(1) << back) != 0 { next = back }
                    else { return nil }

                    if next != direction {
                        corners.append(current)
                        guard vertexCount + corners.count <= maximumContourVertices else { return nil }
                    }
                    direction = next
                }
                // A traced loop may begin in the middle of a straight boundary.
                if direction == firstDirection { corners.removeFirst() }
                guard corners.count >= 4,
                      vertexCount + corners.count <= maximumContourVertices else { return nil }
                vertexCount += corners.count
                contours.append(corners.map { vertex in
                    ImagePoint(x: Double(vertex % stride) / Double(width),
                               y: Double(vertex / stride) / Double(height))
                })
            }
        }
        return contours
    }
}
