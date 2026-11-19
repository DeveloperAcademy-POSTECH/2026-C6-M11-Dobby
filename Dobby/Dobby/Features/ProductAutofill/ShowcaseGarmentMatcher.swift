import CoreGraphics
import Foundation
import ImageIO
import simd
import Vision

nonisolated enum ShowcaseGarment: Sendable, Hashable {
    case chakTee
    case zaraShorts
}

/// Verifies the color and structure of a reference patch after aligning its printed
/// mark or fabric landmarks with the photographed garment.
nonisolated enum ShowcaseGarmentMatcher {
    private struct Reference {
        let garment: ShowcaseGarment
        let points: [Landmark]
        let image: Raster
        let mark: Mark?
        let verifyTail: Bool
    }

    private static let references: [Reference] = [
        (ShowcaseGarment.chakTee, "ShowcaseChakChest"),
        (.chakTee, "ShowcaseChakBack"),
        (.chakTee, "ShowcaseChakFront"),
        (.chakTee, "ShowcaseChakNeck"),
        (.zaraShorts, "ShowcaseZaraPockets"),
        (.zaraShorts, "ShowcaseZaraSeams"),
        (.zaraShorts, "ShowcaseZaraFly"),
        (.zaraShorts, "ShowcaseZaraLabelStitch"),
        (.zaraShorts, "ShowcaseZaraWaistband")
    ].compactMap { garment, name in
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = thumbnail(url), let raster = Raster(image, longest: garment == .zaraShorts ? 45 : 160) else { return nil }
        return Reference(garment: garment, points: garment == .zaraShorts ? landmarks(image) : [], image: raster,
                         mark: garment == .chakTee ? raster.orangeMarks().first : nil, verifyTail: name == "ShowcaseChakBack")
    }

    static func match(photoURLs: [URL]) throws -> ShowcaseGarment? {
        var matches: Set<ShowcaseGarment> = []
        for url in photoURLs {
            try Task.checkCancellation()
            guard let image = thumbnail(url) else { return nil }
            let fullImageMatches = try matchingGarments(in: image)
            matches.formUnion(fullImageMatches)
            if fullImageMatches.isEmpty, let cropped = subjectCrop(image) {
                matches.formUnion(try matchingGarments(in: cropped))
            }
            if matches.count > 1 { return nil }
        }
        try Task.checkCancellation()
        return matches.first
    }

    /// Retry with an enlarged subject if a large capture surface occupies most of the image.
    /// Saliency only proposes a crop; it never identifies a sample.
    private static func subjectCrop(_ image: CGImage) -> CGImage? {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let box = request.results?.first?.salientObjects?.first?.boundingBox,
              box.width * box.height < 0.65, min(box.width, box.height) > 0.12 else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                          width: box.width * width, height: box.height * height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return image.cropping(to: rect.integral.intersection(bounds))
    }

    private static func matchingGarments(in image: CGImage) throws -> Set<ShowcaseGarment> {
        // Compare the fly's wash, label and stitching at a coarser sampling scale:
        // fine denim fibers shift between captures even when the same seams align.
        guard let raster = Raster(image, longest: 640), let denim = Raster(image, longest: 156) else { return [] }
        let marks = raster.orangeMarks()
        var points: [Landmark]?
        var matches: Set<ShowcaseGarment> = []
        for reference in references where !matches.contains(reference.garment) {
            try Task.checkCancellation()
            if let template = reference.mark {
                if marks.contains(where: { matchesPrint($0, template: template, reference: reference, in: raster) }) {
                    matches.insert(reference.garment)
                }
            } else {
                if points == nil { points = landmarks(image) }
                if corresponds(reference, to: points ?? [], image: denim) { matches.insert(reference.garment) }
            }
        }
        return matches
    }

    private static func matchesPrint(_ mark: Mark, template: Mark, reference: Reference, in image: Raster) -> Bool {
        // The circular rear print has no stable major axis. Try orientations around
        // the full circle and verify the distinctive white measuring tape below it.
        let angles: [Float] = reference.verifyTail
            ? (0..<36).map { Float($0) * .pi / 18 }
            : [0, -0.12, 0.12, .pi]
        let shifts: [SIMD2<Float>] = mark.radius < 0.04
            ? [.zero, SIMD2(0.12, 0), SIMD2(-0.12, 0), SIMD2(0, 0.12), SIMD2(0, -0.12)]
            : [.zero]
        for correction: Float in [1, 0.9, 1.1] {
            let scale = mark.radius / template.radius * correction
            for delta in angles {
                let angle = mark.angle - template.angle + delta
                let axis = SIMD2(cos(angle), sin(angle)) * scale
                let transform = simd_float2x2(axis, SIMD2(-axis.y, axis.x))
                let offset = mark.center - transform * template.center
                for shift in shifts where reference.image.matches(image, transform: transform,
                        offset: offset + shift * mark.radius, requireTail: reference.verifyTail) {
                    return true
                }
            }
        }
        return false
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ] as CFDictionary)
    }

    private struct Landmark {
        let position: SIMD2<Float>
        let chroma: SIMD2<Float>
        let bits: SIMD2<UInt64>
    }

    /// A fixed BRIEF sampling pattern. Oriented intensity comparisons tolerate
    /// exposure changes, and Hamming distance makes descriptor lookup inexpensive.
    private static let patterns: [[(SIMD2<Int>, SIMD2<Int>)]] = {
        var seed: UInt32 = 51
        func coordinate() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 24) / 255 * 16 - 8
        }
        let pairs = (0..<128).map { _ in
            (SIMD2(coordinate(), coordinate()), SIMD2(coordinate(), coordinate()))
        }
        return (0..<24).map { bin in
            let angle = Float(bin) * 2 * .pi / 24
            let rotation = simd_float2x2(SIMD2(cos(angle), sin(angle)), SIMD2(-sin(angle), cos(angle)))
            func rotated(_ point: SIMD2<Float>) -> SIMD2<Int> {
                let p = rotation * point
                return SIMD2(Int(p.x.rounded()), Int(p.y.rounded()))
            }
            return pairs.map { (rotated($0.0), rotated($0.1)) }
        }
    }()

    private static func landmarks(_ image: CGImage) -> [Landmark] {
        var points: [Landmark] = []
        let longest = max(image.width, image.height)
        for level in [640, 450, 320, 225, 160, 112] {
            let scale = Float(level) / Float(longest)
            let width = Int(Float(image.width) * scale), height = Int(Float(image.height) * scale)
            guard width > 24, height > 24,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
            defer { withExtendedLifetime(context) {} }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            var luma = [UInt8](repeating: 0, count: width * height)
            for i in luma.indices {
                luma[i] = UInt8((Int(pixels[i * 4]) + 2 * Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2])) / 4)
            }
            var filtered = luma
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    filtered[i] = UInt8((4 * Int(luma[i]) + Int(luma[i - 1]) + Int(luma[i + 1]) + Int(luma[i - width]) + Int(luma[i + width])) / 8)
                }
            }
            points += filtered.withUnsafeBufferPointer { values in
                corners(values, width: width, height: height).map { corner in
                    let x = corner % width, y = corner / width
                    var moment = SIMD2<Float>.zero
                    for dy in stride(from: -6, through: 6, by: 2) {
                        for dx in stride(from: -6, through: 6, by: 2) {
                            moment += SIMD2(Float(dx), Float(dy)) * Float(values[corner + dy * width + dx])
                        }
                    }
                    let bin = (Int((atan2(moment.y, moment.x) * 12 / .pi).rounded()) + 24) % 24
                    var bits = SIMD2<UInt64>.zero
                    for (bit, pair) in patterns[bin].enumerated() {
                        let a = pair.0, b = pair.1
                        if values[corner + a.y * width + a.x] < values[corner + b.y * width + b.x] {
                            bits[bit >> 6] |= 1 << (bit & 63)
                        }
                    }
                    let rgb = pixels.advanced(by: 4 * corner)
                    let chroma = SIMD2(Float(rgb[0]) - Float(rgb[1]), Float(rgb[2]) - Float(rgb[1]))
                    return Landmark(position: SIMD2(Float(x), Float(y)) / Float(level),
                                    chroma: chroma, bits: bits)
                }
            }
        }
        return points
    }

    /// Keep the strongest corner in each cell to avoid letting a single letter
    /// or patch of denim texture dominate the correspondence check.
    private static func corners(_ gray: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> [Int] {
        let cell = 12, columns = (width + cell - 1) / cell
        var best = [(index: Int, score: Int)](repeating: (0, 0), count: columns * ((height + cell - 1) / cell))
        for y in stride(from: 12, to: height - 12, by: 2) {
            for x in stride(from: 12, to: width - 12, by: 2) {
                let i = y * width + x
                // The smaller eigenvalue of the local structure tensor is
                // large at a corner and small along a single straight edge.
                var xx = 0, yy = 0, xy = 0
                for neighbor in [i - 2 * width - 2, i - 2 * width + 2, i + 2 * width - 2, i + 2 * width + 2] {
                    let gx = Int(gray[neighbor + 2]) - Int(gray[neighbor - 2])
                    let gy = Int(gray[neighbor + 2 * width]) - Int(gray[neighbor - 2 * width])
                    xx += gx * gx
                    yy += gy * gy
                    xy += gx * gy
                }
                let score = (xx * yy - xy * xy) / max(1, xx + yy)
                let slot = y / cell * columns + x / cell
                if score > 65 && score > best[slot].score { best[slot] = (i, score) }
            }
        }
        return best.filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(180).map(\.index)
    }

    private struct Mark {
        let center: SIMD2<Float>
        let radius: Float
        let angle: Float
    }

    private struct Correlation {
        var count: Float = 0
        private var sum = SIMD2<Float>.zero
        private var squares = SIMD2<Float>.zero
        private var products: Float = 0

        mutating func sample(_ a: Float, _ b: Float) {
            let pair = SIMD2(a, b)
            sum += pair
            squares += pair * pair
            products += a * b
            count += 1
        }

        func score(minimumVariance: Float = 0) -> Float {
            guard count > 0 else { return -1 }
            let energy = squares - sum * sum / count
            guard min(energy.x, energy.y) > minimumVariance * count else { return -1 }
            return (products - sum.x * sum.y / count) / sqrt(energy.x * energy.y)
        }
    }

    private struct Raster {
        let width: Int
        let height: Int
        let size: Float
        let pixels: [UInt8]

        init?(_ image: CGImage, longest: Int) {
            let scale = Double(longest) / Double(max(image.width, image.height))
            width = max(1, Int(Double(image.width) * scale))
            height = max(1, Int(Double(image.height) * scale))
            size = Float(longest)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let data = context.data else { return nil }
            defer { withExtendedLifetime(context) {} }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        }

        /// Locate the burnt-orange ink in the shirt's print. Its color and
        /// centroid only propose alignments; the surrounding graphic must also match.
        func orangeMarks() -> [Mark] {
            let cell = 4, columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
            var grid = [[SIMD2<Float>]](repeating: [], count: columns * rows)
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let i = (width * y + x) * 4
                    let red = Int(pixels[i]), green = Int(pixels[i + 1]), blue = Int(pixels[i + 2])
                    if red - green > max(20, green / 5), green >= blue, red - blue > 30 {
                        grid[y / cell * columns + x / cell].append(SIMD2(Float(x), Float(y)) / size)
                    }
                }
            }
            var marks: [Mark] = []
            var visited = [Bool](repeating: false, count: grid.count)
            for start in grid.indices where !grid[start].isEmpty && !visited[start] {
                var queue = [start], points: [SIMD2<Float>] = []
                visited[start] = true
                while let index = queue.popLast() {
                    points.append(contentsOf: grid[index])
                    let x = index % columns, y = index / columns
                    for row in max(0, y - 2)...min(rows - 1, y + 2) {
                        for col in max(0, x - 2)...min(columns - 1, x + 2) {
                            let next = row * columns + col
                            if !visited[next], !grid[next].isEmpty {
                                visited[next] = true
                                queue.append(next)
                            }
                        }
                    }
                }
                guard points.count >= 10 else { continue }
                let center = points.reduce(.zero, +) / Float(points.count)
                var xx: Float = 0, yy: Float = 0, xy: Float = 0
                for point in points {
                    let delta = point - center
                    xx += delta.x * delta.x
                    yy += delta.y * delta.y
                    xy += delta.x * delta.y
                }
                marks.append(Mark(center: center, radius: sqrt((xx + yy) / Float(points.count)),
                                  angle: atan2(2 * xy, xx - yy) / 2))
            }
            return marks.sorted { $0.radius > $1.radius }
        }

        // Verify the actual pattern across the patch after geometric alignment.
        // This rejects matches made up of repeated strokes from a brand label or seams.
        func matches(_ other: Raster, transform: simd_float2x2, offset: SIMD2<Float>, requireTail: Bool = false) -> Bool {
            similarity(other, transform: transform, offset: offset, divisions: 6) > 0.63
                && similarity(other, transform: transform, offset: offset, divisions: 20, requireTail: requireTail) > 0.82
        }

        func similarity(_ other: Raster, transform: simd_float2x2, offset: SIMD2<Float>, divisions: Int,
                        requireTail: Bool = false) -> Float {
            var pattern = Correlation(), tail = Correlation()
            var chromaError: Float = 0
            for row in 0..<divisions {
                let y = (2 * row + 1) * height / (divisions * 2)
                for column in 0..<divisions {
                    let x = (2 * column + 1) * width / (divisions * 2)
                    let query = (transform * (SIMD2(Float(x), Float(y)) / size) + offset) * other.size
                    let qx = Int(query.x.rounded()), qy = Int(query.y.rounded())
                    guard qx >= 0, qx < other.width, qy >= 0, qy < other.height else { continue }
                    let a = 4 * (y * width + x), b = 4 * (qy * other.width + qx)
                    let redA = Float(pixels[a]), greenA = Float(pixels[a + 1]), blueA = Float(pixels[a + 2])
                    let redB = Float(other.pixels[b]), greenB = Float(other.pixels[b + 1]), blueB = Float(other.pixels[b + 2])
                    let va = (redA + 2 * greenA + blueA) / 4, vb = (redB + 2 * greenB + blueB) / 4
                    pattern.sample(va, vb)
                    if requireTail && divisions > 6 && row >= divisions * 2 / 3 { tail.sample(va, vb) }
                    chromaError += abs((redA - greenA) - (redB - greenB)) + abs((blueA - greenA) - (blueB - greenB))
                }
            }
            guard pattern.count >= Float(divisions * divisions) * 0.82,
                  chromaError < 32 * pattern.count else { return -1 }
            if requireTail && tail.score() <= 0.6 { return -1 }
            return pattern.score(minimumVariance: 18)
        }
    }

    private struct Pair {
        let from: SIMD2<Float>
        let to: SIMD2<Float>
        let distance: Int
    }

    private static func corresponds(_ reference: Reference, to candidates: [Landmark], image: Raster) -> Bool {
        var pairs: [Pair] = []
        for ref in reference.points {
            var first = 129, second = 129, nearest: Landmark?
            for point in candidates {
                guard simd_distance_squared(ref.chroma, point.chroma) < 24 * 24 else { continue }
                let difference = ref.bits ^ point.bits
                let distance = difference.x.nonzeroBitCount + difference.y.nonzeroBitCount
                if distance < first {
                    second = first
                    first = distance
                    nearest = point
                } else if distance < second {
                    second = distance
                }
            }
            if let nearest, first < 31, first * 8 < second * 7 {
                pairs.append(Pair(from: ref.position, to: nearest.position, distance: first))
            }
        }
        // Repeated pyramid detections of the same physical corner count once.
        var distinct: [Pair] = []
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) {
            if distinct.allSatisfy({ simd_distance_squared($0.from, pair.from) > 0.0002
                && simd_distance_squared($0.to, pair.to) > 0.00005 }) {
                distinct.append(pair)
                if distinct.count == 60 { break }
            }
        }
        guard distinct.count >= 2 else { return false }
        var candidatesToRefine: [(score: Float, alignment: Alignment)] = []
        for (index, a) in distinct.enumerated() {
            for b in distinct.dropFirst(index + 1) {
                let source = b.from - a.from, target = b.to - a.to
                let length = simd_length_squared(source)
                guard length > 0.015, simd_length_squared(target) > 0.0001 else { continue }
                let rotation = SIMD2(simd_dot(source, target), source.x * target.y - source.y * target.x) / length
                let transform = simd_float2x2(rotation, SIMD2(-rotation.y, rotation.x))
                let offset = a.to - transform * a.from
                guard reference.image.similarity(image, transform: transform, offset: offset, divisions: 6) > 0.48 else { continue }
                let score = reference.image.similarity(image, transform: transform, offset: offset, divisions: 12)
                if score > 0.83 && reference.image.matches(image, transform: transform, offset: offset) { return true }
                guard score > 0.44 else { continue }
                if candidatesToRefine.count < 3 || score > candidatesToRefine[2].score {
                    let insertion = candidatesToRefine.firstIndex { score > $0.score } ?? candidatesToRefine.endIndex
                    candidatesToRefine.insert((score, Alignment(transform: transform, offset: offset)), at: insertion)
                    if candidatesToRefine.count > 3 { candidatesToRefine.removeLast() }
                }
            }
        }
        return candidatesToRefine.contains { $0.alignment.refinedMatch(reference: reference.image, photo: image) }
    }

    private struct Alignment {
        var transform: simd_float2x2
        var offset: SIMD2<Float>

        /// Nearby landmark pairs establish where to look. The best few placements
        /// account for camera angle and the way the cloth hangs.
        func refinedMatch(reference: Raster, photo: Raster) -> Bool {
            var best = self
            let center = SIMD2(Float(reference.width), Float(reference.height)) / (2 * reference.size)
            let scale = simd_length(transform.columns.0)
            for step: Float in [0.065, 0.035, 0.018, 0.01] {
                var bestScore = best.score(reference: reference, photo: photo, divisions: 16)
                // Translate in x/y, then adjust each axis of the linear transform around the patch center.
                for parameter in 0..<6 {
                    let start = best
                    for direction: Float in [-1, 1] {
                        var candidate = start
                        let delta = direction * step * scale
                        if parameter < 2 {
                            candidate.offset[parameter] += delta
                        } else {
                            let column = (parameter - 2) / 2, row = (parameter - 2) % 2
                            candidate.transform[column][row] += 2 * delta
                            candidate.offset[row] -= 2 * delta * center[column]
                        }
                        let score = candidate.score(reference: reference, photo: photo, divisions: 16)
                        if score > bestScore {
                            bestScore = score
                            best = candidate
                        }
                    }
                }
            }
            // Verify with a denser, independent sampling grid and the same required correlation.
            return best.score(reference: reference, photo: photo, divisions: 24) > 0.82
        }

        private func score(reference: Raster, photo: Raster, divisions: Int) -> Float {
            reference.similarity(photo, transform: transform, offset: offset, divisions: divisions)
        }
    }

}
