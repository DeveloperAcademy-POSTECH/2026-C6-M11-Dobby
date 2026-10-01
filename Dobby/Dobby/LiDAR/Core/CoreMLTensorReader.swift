#if canImport(CoreML)
import CoreML
import Foundation

/// Scoped scalar access avoids an NSNumber/index-array allocation for every YOLO
/// anchor. Buffer bounds and the actual strides are checked before any load.
nonisolated enum CoreMLTensorReader {
    static func decode(tensor: MLMultiArray, schema: BottomLandmarkSchema,
                       geometry: BottomLetterboxGeometry) throws -> BottomLandmarkPrediction {
        let shape = tensor.shape.map(\.intValue)
        let decoder = BottomLandmarkDecoder(schema: schema)
        let scalarBytes: Int
        switch tensor.dataType {
        case .float16: scalarBytes = MemoryLayout<Float16>.stride
        case .float32: scalarBytes = MemoryLayout<Float>.stride
        case .double: scalarBytes = MemoryLayout<Double>.stride
        default: throw BottomLandmarkError.invalidOutputShape
        }
        return try tensor.withUnsafeBytes { bytes in
            // Query inside the scoped access in case Core ML materialized a
            // different backing buffer before handing it to this closure.
            let strides = tensor.strides.map(\.intValue)
            try validateLayout(shape: shape, strides: strides, byteCount: bytes.count,
                               scalarByteWidth: scalarBytes)
            switch tensor.dataType {
            case .float16:
                return try decoder.decode(shape: shape, geometry: geometry) { channel, anchor in
                    Double(bytes.loadUnaligned(fromByteOffset: (channel * strides[1] + anchor * strides[2]) * scalarBytes,
                                               as: Float16.self))
                }
            case .float32:
                return try decoder.decode(shape: shape, geometry: geometry) { channel, anchor in
                    Double(bytes.loadUnaligned(fromByteOffset: (channel * strides[1] + anchor * strides[2]) * scalarBytes,
                                               as: Float.self))
                }
            case .double:
                return try decoder.decode(shape: shape, geometry: geometry) { channel, anchor in
                    bytes.loadUnaligned(fromByteOffset: (channel * strides[1] + anchor * strides[2]) * scalarBytes,
                                        as: Double.self)
                }
            default: throw BottomLandmarkError.invalidOutputShape
            }
        }
    }

    static func validateLayout(shape: [Int], strides: [Int], byteCount: Int,
                               scalarByteWidth: Int) throws {
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[1] <= 389,
              shape[2] > 0, shape[2] <= 100_000, strides.count == 3,
              strides.allSatisfy({ $0 >= 0 }), byteCount > 0, scalarByteWidth > 0 else {
            throw BottomLandmarkError.invalidOutputShape
        }
        var maximumOffset = 0
        for axis in shape.indices {
            let contribution = (shape[axis] - 1).multipliedReportingOverflow(by: strides[axis])
            let sum = maximumOffset.addingReportingOverflow(contribution.partialValue)
            guard !contribution.overflow, !sum.overflow else { throw BottomLandmarkError.invalidOutputShape }
            maximumOffset = sum.partialValue
        }
        let scalarCount = maximumOffset.addingReportingOverflow(1)
        let neededBytes = scalarCount.partialValue.multipliedReportingOverflow(by: scalarByteWidth)
        guard !scalarCount.overflow, !neededBytes.overflow, neededBytes.partialValue <= byteCount else {
            throw BottomLandmarkError.invalidOutputShape
        }
    }
}
#endif
