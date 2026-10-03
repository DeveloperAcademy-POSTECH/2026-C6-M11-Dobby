import Foundation

/// Display geometry for one foreground, independent of semantic clothing,
/// landmark confidence, depth and capture eligibility.
nonisolated struct LiveForegroundPreviewSelection: Sendable {
    let state: LiveReadinessState
    var bounds: NormalizedRect? = nil
    var mask: GarmentMask? = nil

    func readiness(timestamp: TimeInterval) -> LiveCaptureReadiness {
        // No kind/model version, so garmentRecognized/isReady stay false.
        .init(state: state, timestamp: timestamp, bounds: bounds, silhouette: mask)
    }
}

nonisolated enum LiveForegroundPreviewSelectionPolicy {
    static let maximumRasterDimension = 512

    static func select(masks: [GarmentMask], imageSize: PixelSize) -> LiveForegroundPreviewSelection {
        guard imageSize.isValid else { return .init(state: .analysisFailed) }
        guard !masks.isEmpty else { return .init(state: .searching) }
        guard masks.count == 1 else { return .init(state: .multipleObjects) }
        let mask = masks[0]
        let width = mask.size.width, height = mask.size.height
        guard mask.size.isValid, max(width, height) <= maximumRasterDimension,
              width * imageSize.height == height * imageSize.width,
              mask.values.count == width * height, mask.values.allSatisfy({ $0 <= 1 }) else {
            return .init(state: .analysisFailed)
        }
        var foregroundCount = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for index in mask.values.indices where mask.values[index] == 1 {
            foregroundCount += 1
            let x = index % width, y = index / width
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        guard foregroundCount > 0 else { return .init(state: .searching) }
        let bounds = NormalizedRect(x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width), height: Double(maxY - minY + 1) / Double(height))
        let margin = 0.015
        guard bounds.x >= margin, bounds.y >= margin,
              bounds.x + bounds.width <= 1 - margin, bounds.y + bounds.height <= 1 - margin else {
            return .init(state: .clipped)
        }
        let fraction = Double(foregroundCount) / Double(mask.values.count)
        guard fraction >= 0.04, bounds.width >= 0.12, bounds.height >= 0.12 else {
            return .init(state: .tooSmall)
        }
        // Almost whole-frame masks give no useful foreground/background guide.
        guard fraction <= 0.80, bounds.width * bounds.height <= 0.90 else {
            return .init(state: .searching)
        }
        guard hasOneSignificantComponent(mask, foregroundCount: foregroundCount) else {
            return .init(state: .multipleObjects)
        }
        // Keep every selected pixel and hole. This does not certify clothing,
        // correct landmarks, sensor quality or readiness for measurement.
        return .init(state: .analyzing, bounds: bounds, mask: mask)
    }

    private static func hasOneSignificantComponent(_ mask: GarmentMask, foregroundCount: Int) -> Bool {
        let width = mask.size.width, height = mask.size.height
        var visited = [Bool](repeating: false, count: mask.values.count)
        var queue: [Int] = []
        queue.reserveCapacity(foregroundCount)
        var largest = 0
        for seed in mask.values.indices where mask.values[seed] == 1 && !visited[seed] {
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            visited[seed] = true
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width, y = index / width
                // Eight neighbours preserve diagonal pixel edges.
                for neighborY in max(0, y - 1)...min(height - 1, y + 1) {
                    for neighborX in max(0, x - 1)...min(width - 1, x + 1) {
                        let neighbor = neighborY * width + neighborX
                        if !visited[neighbor], mask.values[neighbor] == 1 {
                            visited[neighbor] = true
                            queue.append(neighbor)
                        }
                    }
                }
            }
            largest = max(largest, queue.count)
        }
        // A second material component is ambiguous even within one instance.
        // Tiny segmentation speckles are retained, never erased.
        return Double(largest) / Double(foregroundCount) >= 0.98
    }
}
