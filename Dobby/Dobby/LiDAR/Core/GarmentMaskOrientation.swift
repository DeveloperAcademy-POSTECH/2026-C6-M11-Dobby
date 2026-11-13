import Foundation

/// Restore an upright binary segmentation to the complete, unrotated RGB grid.
/// A quarter turn is an exact pixel permutation; interpolation must not fill holes
/// or move a silhouette relative to the raw depth registered to that RGB frame.
nonisolated enum GarmentMaskOrientation {
    static func uprightMask(fromOriginal mask: GarmentMask,
                            orientation: ImageOrientation) throws -> GarmentMask {
        let inverse: ImageOrientation
        switch orientation {
        case .up: inverse = .up
        case .right: inverse = .left
        case .down: inverse = .down
        case .left: inverse = .right
        }
        return try originalMask(fromUpright: mask, orientation: inverse)
    }

    static func originalMask(fromUpright mask: GarmentMask,
                             orientation: ImageOrientation) throws -> GarmentMask {
        guard mask.size.isValid, mask.values.count <= 4_194_304,
              mask.values.count == mask.size.width * mask.size.height,
              mask.values.allSatisfy({ $0 <= 1 }) else {
            throw GarmentMaskAssociationError.invalidMask
        }
        guard orientation != .up else { return mask }
        let quarterTurn = orientation == .right || orientation == .left
        let width = quarterTurn ? mask.size.height : mask.size.width
        let height = quarterTurn ? mask.size.width : mask.size.height
        var values = Array(repeating: UInt8(0), count: mask.values.count)
        for y in 0..<height {
            for x in 0..<width {
                let sourceX: Int, sourceY: Int
                switch orientation {
                case .up: sourceX = x; sourceY = y
                case .right: sourceX = height - 1 - y; sourceY = x
                case .down: sourceX = width - 1 - x; sourceY = height - 1 - y
                case .left: sourceX = y; sourceY = width - 1 - x
                }
                values[y * width + x] = mask.values[sourceY * mask.size.width + sourceX]
            }
        }
        return .init(size: .init(width: width, height: height), values: values)
    }
}
