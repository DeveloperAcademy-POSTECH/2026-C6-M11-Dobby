import Foundation

/// Display-only geometry. The measured mask and its exact pixel boundary remain
/// unchanged. In mask-pixel space, simplification and convex-hull corner rounding
/// move the displayed boundary by at most two mask pixels. Simple shapes use a
/// tighter budget; a slanted one-pixel staircase can require adaptive tolerance.
nonisolated enum GarmentSilhouettePresentationGeometry {
    static let samplesPerContour = 128
    static let maximumContours = 16
    static let maximumDisplayDeviationPixels = 2.0
    // First-fit capacity alone can retain visible one-pixel staircase corners
    // on nearly vertical legs/sleeves. A 1.25px start also removes diagonal
    // raster zigzags while retaining the overall two-pixel display budget.
    private static let simplificationBudgets = [1.25, 1.5, 1.7]
    private static let roundingPixels = 0.3
    private static let maximumSimplificationWork = 262_144

    /// Closed loops omit the repeated closing point. All loops have 128 points,
    /// retain their winding and nesting, and are suitable for even-odd filling.
    /// Returns nil instead of dropping a hole/component when capacity is exceeded.
    static func contours(from mask: GarmentMask) -> [[ImagePoint]]? {
        guard let exact = GarmentSilhouetteGeometry.contours(from: mask) else { return nil }
        return contours(fromExactContours: exact, size: mask.size)
    }

    /// Reuses the exact pixel boundaries from GarmentSilhouetteGeometry, so a
    /// caller can fall back to those boundaries without tracing the mask again.
    /// This applies the same display budget and topology checks as the mask API.
    static func contours(fromExactContours exact: [[ImagePoint]], size: PixelSize) -> [[ImagePoint]]? {
        guard size.isValid,
              size.width <= GarmentSilhouetteGeometry.maximumMaskDimension,
              size.height <= GarmentSilhouetteGeometry.maximumMaskDimension,
              exact.count <= maximumContours,
              exact.reduce(0, { $0 + $1.count }) <= GarmentSilhouetteGeometry.maximumContourVertices,
              exact.allSatisfy({ loop in
                  loop.count >= 4 && loop.allSatisfy(isValidDisplayPoint)
                      && loop.indices.allSatisfy {
                          squaredDistance(loop[$0], loop[($0 + 1) % loop.count]) > 1e-20
                      }
              }) else { return nil }
        if exact.isEmpty { return [] }
        var output: [[ImagePoint]] = []
        for loop in exact {
            let pixels = loop.map { ImagePoint(x: $0.x * Double(size.width),
                                               y: $0.y * Double(size.height)) }
            var work = 0
            var simplified: [ImagePoint]?
            for tolerance in simplificationBudgets {
                guard let candidate = simplifyClosed(pixels, tolerance: tolerance, work: &work) else { return nil }
                if candidate.count <= samplesPerContour { simplified = candidate; break }
            }
            guard let simplified else { return nil }
            let anchors = roundedAnchors(simplified)
            guard let sampled = densify(anchors, count: samplesPerContour) else { return nil }
            output.append(sampled.map { .init(x: $0.x / Double(size.width),
                                              y: $0.y / Double(size.height)) })
        }
        guard hasSameTopology(output, as: exact) else { return nil }
        return output
    }

    /// Phase correspondence is deliberately limited to one simple outer loop.
    /// Holes, components, large shape changes or crossing intermediate polygons
    /// require a fade between complete paths, rather than a misleading path morph.
    static func aligned(_ next: [[ImagePoint]], to previous: [[ImagePoint]]) -> [[ImagePoint]]? {
        guard hasCompatibleEndpoints(next, previous) else { return nil }
        let incoming = next[0], old = previous[0]
        var bestShift = 0, bestCost = Double.infinity
        for shift in incoming.indices {
            var cost = 0.0
            for index in old.indices {
                let point = incoming[(index + shift) % incoming.count]
                cost += squaredDistance(point, old[index])
            }
            if cost < bestCost { bestCost = cost; bestShift = shift }
        }
        let aligned = old.indices.map { incoming[($0 + bestShift) % incoming.count] }
        guard hasSafeInterpolation(aligned, from: old) else { return nil }
        return [aligned]
    }

    /// Checks the actual displayed path against a new target without changing
    /// its vertex correspondence. A running native morph retains that order.
    /// Sampled intermediates use the same safety checks as phase alignment.
    static func canInterpolate(_ next: [[ImagePoint]], from previous: [[ImagePoint]]) -> Bool {
        hasCompatibleEndpoints(next, previous) && hasSafeInterpolation(next[0], from: previous[0])
    }

    private static func hasCompatibleEndpoints(_ next: [[ImagePoint]], _ previous: [[ImagePoint]]) -> Bool {
        guard next.count == 1, previous.count == 1,
              next[0].count == samplesPerContour, previous[0].count == samplesPerContour,
              isSimple(next[0]), isSimple(previous[0]) else { return false }
        let oldArea = signedArea(previous[0]), newArea = signedArea(next[0])
        return oldArea > 1e-10 && newArea > 1e-10
            && (0.8...1.25).contains(newArea / oldArea)
            && distance(center(previous[0]), center(next[0])) <= 0.035
    }

    private static func hasSafeInterpolation(_ next: [ImagePoint], from previous: [ImagePoint]) -> Bool {
        guard zip(next, previous).allSatisfy({ distance($0.0, $0.1) <= 0.06 }) else { return false }
        for fraction in [0.25, 0.5, 0.75] {
            let intermediate = zip(previous, next).map {
                ImagePoint(x: $0.0.x + ($0.1.x - $0.0.x) * fraction,
                           y: $0.0.y + ($0.1.y - $0.0.y) * fraction)
            }
            guard signedArea(intermediate) > 1e-10, isSimple(intermediate) else { return false }
        }
        return true
    }

    private static func simplifyClosed(_ loop: [ImagePoint], tolerance: Double, work: inout Int) -> [ImagePoint]? {
        guard loop.count >= 3 else { return nil }
        // Pixel rectangles, including one-pixel holes, already have minimal
        // geometry. Their two diagonals must not collapse them into two points.
        if loop.count <= 4 { return loop }
        let split = loop.indices.max { squaredDistance(loop[$0], loop[0]) < squaredDistance(loop[$1], loop[0]) }!
        guard split > 0 else { return nil }
        guard let first = simplifyOpen(Array(loop[0...split]), tolerance: tolerance, work: &work),
              let second = simplifyOpen(Array(loop[split...]) + [loop[0]], tolerance: tolerance, work: &work) else { return nil }
        let result = Array(first.dropLast()) + Array(second.dropLast())
        return result.count >= 3 ? result : nil
    }

    private static func simplifyOpen(_ points: [ImagePoint], tolerance: Double, work: inout Int) -> [ImagePoint]? {
        var keep = Set([0, points.count - 1])
        var pending = [(0, points.count - 1)]
        while let (first, last) = pending.popLast() {
            guard last > first + 1 else { continue }
            var maximum = tolerance * tolerance
            var split: Int?
            for index in (first + 1)..<last {
                work += 1
                guard work <= maximumSimplificationWork else { return nil }
                let error = squaredDistanceToSegment(points[index], points[first], points[last])
                if error > maximum { maximum = error; split = index }
            }
            if let split {
                keep.insert(split)
                pending.append((first, split)); pending.append((split, last))
            }
        }
        return keep.sorted().map { points[$0] }
    }

    private static func roundedAnchors(_ loop: [ImagePoint]) -> [ImagePoint] {
        // Mandatory anchors are never omitted by uniform sampling. In particular,
        // a short neck/armpit notch cannot disappear between two long-edge samples.
        let samples = loop.count * 3 <= samplesPerContour ? 3 : (loop.count * 2 <= samplesPerContour ? 2 : 1)
        if samples == 1 { return loop }
        var output: [ImagePoint] = []
        for index in loop.indices {
            let before = loop[(index + loop.count - 1) % loop.count]
            let corner = loop[index], after = loop[(index + 1) % loop.count]
            let incoming = distance(before, corner), outgoing = distance(corner, after)
            let radius = min(roundingPixels, incoming * 0.2, outgoing * 0.2)
            let entry = interpolate(corner, before, radius / incoming)
            let exit = interpolate(corner, after, radius / outgoing)
            output.append(entry)
            if samples == 3 {
                // Quadratic Bezier at t=1/2: stays inside entry/corner/exit's
                // convex hull, so smoothing cannot overshoot a sleeve or notch.
                output.append(.init(x: (entry.x + 2 * corner.x + exit.x) / 4,
                                    y: (entry.y + 2 * corner.y + exit.y) / 4))
            }
            output.append(exit)
        }
        return output
    }

    private static func densify(_ anchors: [ImagePoint], count: Int) -> [ImagePoint]? {
        guard anchors.count >= 3, anchors.count <= count else { return nil }
        let lengths = anchors.indices.map { distance(anchors[$0], anchors[($0 + 1) % anchors.count]) }
        let perimeter = lengths.reduce(0, +)
        guard perimeter.isFinite, perimeter > 0, lengths.allSatisfy({ $0 > 1e-12 }) else { return nil }
        let additional = count - anchors.count
        let exact = lengths.map { Double(additional) * $0 / perimeter }
        var allocations = exact.map { Int($0) }
        let remainder = additional - allocations.reduce(0, +)
        let priorities = exact.indices.sorted { exact[$0] - Double(allocations[$0]) > exact[$1] - Double(allocations[$1]) }
        for index in priorities.prefix(remainder) { allocations[index] += 1 }
        var output: [ImagePoint] = []
        for index in anchors.indices {
            output.append(anchors[index])
            for step in 0..<allocations[index] {
                output.append(interpolate(anchors[index], anchors[(index + 1) % anchors.count],
                    Double(step + 1) / Double(allocations[index] + 1)))
            }
        }
        return output
    }

    private static func hasSameTopology(_ candidate: [[ImagePoint]], as reference: [[ImagePoint]]) -> Bool {
        guard candidate.count == reference.count,
              candidate.allSatisfy({ $0.allSatisfy(isValidDisplayPoint) && isSimple($0) }) else { return false }
        for index in candidate.indices {
            let area = signedArea(candidate[index]), originalArea = signedArea(reference[index])
            guard abs(area) > 1e-12, area * originalArea > 0 else { return false }
            for other in candidate.indices where other != index {
                guard contains(interiorPoint(candidate[index]), in: candidate[other])
                        == contains(interiorPoint(reference[index]), in: reference[other]) else { return false }
                if other > index, loopsIntersect(candidate[index], candidate[other]) { return false }
            }
        }
        return true
    }

    private static func isSimple(_ loop: [ImagePoint]) -> Bool {
        guard loop.count >= 3, loop.allSatisfy(isValidDisplayPoint) else { return false }
        for first in loop.indices {
            let a = loop[first], b = loop[(first + 1) % loop.count]
            guard squaredDistance(a, b) > 1e-20 else { return false }
            for second in (first + 1)..<loop.count {
                if second == first + 1 || (first == 0 && second == loop.count - 1) { continue }
                if segmentsIntersect(a, b, loop[second], loop[(second + 1) % loop.count]) { return false }
            }
        }
        return true
    }

    private static func loopsIntersect(_ first: [ImagePoint], _ second: [ImagePoint]) -> Bool {
        let epsilon = 1e-12
        // Separate holes/components often have disjoint bounds. Reject those
        // pairs before O(n*m) edge checks, retaining the same inclusive contact
        // tolerance as segmentsIntersect for touching or nested loop bounds.
        guard let firstMinX = first.map(\.x).min(), let firstMaxX = first.map(\.x).max(),
              let firstMinY = first.map(\.y).min(), let firstMaxY = first.map(\.y).max(),
              let secondMinX = second.map(\.x).min(), let secondMaxX = second.map(\.x).max(),
              let secondMinY = second.map(\.y).min(), let secondMaxY = second.map(\.y).max(),
              firstMaxX + epsilon >= secondMinX, secondMaxX + epsilon >= firstMinX,
              firstMaxY + epsilon >= secondMinY, secondMaxY + epsilon >= firstMinY else { return false }
        for i in first.indices { for j in second.indices {
            if segmentsIntersect(first[i], first[(i + 1) % first.count], second[j], second[(j + 1) % second.count]) { return true }
        } }
        return false
    }

    private static func segmentsIntersect(_ a: ImagePoint, _ b: ImagePoint, _ c: ImagePoint, _ d: ImagePoint) -> Bool {
        let epsilon = 1e-12
        guard max(a.x, b.x) + epsilon >= min(c.x, d.x), max(c.x, d.x) + epsilon >= min(a.x, b.x),
              max(a.y, b.y) + epsilon >= min(c.y, d.y), max(c.y, d.y) + epsilon >= min(a.y, b.y) else { return false }
        func cross(_ p: ImagePoint, _ q: ImagePoint, _ r: ImagePoint) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        return ((abC <= epsilon && abD >= -epsilon) || (abD <= epsilon && abC >= -epsilon))
            && ((cdA <= epsilon && cdB >= -epsilon) || (cdB <= epsilon && cdA >= -epsilon))
    }

    private static func interiorPoint(_ loop: [ImagePoint]) -> ImagePoint {
        let a = loop[0], b = loop[1], sign = signedArea(loop) > 0 ? 1.0 : -1.0
        let length = distance(a, b)
        return .init(x: (a.x + b.x) / 2 - sign * (b.y - a.y) / length * 1e-8,
                     y: (a.y + b.y) / 2 + sign * (b.x - a.x) / length * 1e-8)
    }

    private static func contains(_ point: ImagePoint, in loop: [ImagePoint]) -> Bool {
        var inside = false
        for index in loop.indices {
            let a = loop[index], b = loop[(index + 1) % loop.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    private static func signedArea(_ loop: [ImagePoint]) -> Double {
        loop.indices.reduce(0) { $0 + loop[$1].x * loop[($1 + 1) % loop.count].y
            - loop[($1 + 1) % loop.count].x * loop[$1].y } / 2
    }

    private static func center(_ loop: [ImagePoint]) -> ImagePoint {
        .init(x: ((loop.map(\.x).min() ?? 0) + (loop.map(\.x).max() ?? 0)) / 2,
              y: ((loop.map(\.y).min() ?? 0) + (loop.map(\.y).max() ?? 0)) / 2)
    }

    private static func interpolate(_ a: ImagePoint, _ b: ImagePoint, _ fraction: Double) -> ImagePoint {
        .init(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }

    private static func squaredDistance(_ a: ImagePoint, _ b: ImagePoint) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    private static func distance(_ a: ImagePoint, _ b: ImagePoint) -> Double { sqrt(squaredDistance(a, b)) }

    private static func squaredDistanceToSegment(_ p: ImagePoint, _ a: ImagePoint, _ b: ImagePoint) -> Double {
        let length = squaredDistance(a, b)
        guard length > 0 else { return squaredDistance(p, a) }
        let fraction = max(0, min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / length))
        return squaredDistance(p, interpolate(a, b, fraction))
    }

    private static func isValidDisplayPoint(_ point: ImagePoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }
}
