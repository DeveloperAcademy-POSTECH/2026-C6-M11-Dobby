#if canImport(CoreML)
import CoreML
import Foundation
import XCTest
@testable import DobbyLiDARCore

final class CoreMLTensorReaderTests: XCTestCase {
    private func schema() throws -> BottomLandmarkSchema {
        try .init(jsonData: JSONSerialization.data(withJSONObject: [
            "name": "test", "keypoints": ["A", "B", "C"], "skeleton": [["A", "B"]]
        ]))
    }

    private func values() -> [[Double]] {
        var values = Array(repeating: Array(repeating: 0.0, count: 4), count: 14)
        let anchor = 2
        values[0][anchor] = 320; values[1][anchor] = 320
        values[2][anchor] = 400; values[3][anchor] = 400; values[4][anchor] = 0.9
        for (index, point) in [(160.0, 120.0), (480.0, 120.0), (320.0, 520.0)].enumerated() {
            values[5 + 3 * index][anchor] = point.0
            values[6 + 3 * index][anchor] = point.1
            values[7 + 3 * index][anchor] = 0.83 - Double(index) * 0.1
        }
        return values
    }

    private func tensor(dataType: MLMultiArrayDataType, strides: [Int]) throws -> MLMultiArray {
        let scalarBytes: Int
        switch dataType {
        case .float16: scalarBytes = 2
        case .float32, .int32: scalarBytes = 4
        default: scalarBytes = 8
        }
        let capacity = (13 * strides[1] + 3 * strides[2] + 1) * scalarBytes
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        let tensor: MLMultiArray
        do {
            tensor = try .init(dataPointer: storage, shape: [1, 14, 4], dataType: dataType,
                               strides: strides.map(NSNumber.init(value:)), deallocator: { $0.deallocate() })
        } catch {
            storage.deallocate()
            throw error
        }
        let values = values()
        for channel in values.indices {
            for anchor in values[channel].indices {
                tensor[[0, NSNumber(value: channel), NSNumber(value: anchor)]] = NSNumber(value: values[channel][anchor])
            }
        }
        return tensor
    }

    func testMatchesBoxedDecoderForFloat16Float32AndDoubleAcrossPaddedAndTransposedLayouts() throws {
        let geometry = try BottomLetterboxGeometry(originalSize: .init(width: 640, height: 640), orientation: .up)
        let schema = try schema()
        for dataType in [MLMultiArrayDataType.float16, .float32, .double] {
            for strides in [[56, 4, 1], [120, 8, 2], [56, 1, 14]] {
                let tensor = try tensor(dataType: dataType, strides: strides)
                let boxed = try BottomLandmarkDecoder(schema: schema).decode(shape: [1, 14, 4], geometry: geometry) { channel, anchor in
                    tensor[[0, NSNumber(value: channel), NSNumber(value: anchor)]].doubleValue
                }
                let fast = try CoreMLTensorReader.decode(tensor: tensor, schema: schema, geometry: geometry)
                XCTAssertEqual(fast.detectionConfidence, boxed.detectionConfidence)
                XCTAssertEqual(fast.points.map(\.id), boxed.points.map(\.id))
                XCTAssertEqual(fast.points.map(\.point), boxed.points.map(\.point), "dtype \(dataType), strides \(strides)")
                XCTAssertEqual(fast.points.map(\.confidence), boxed.points.map(\.confidence))
                XCTAssertEqual(fast.points.map(\.isVisible), boxed.points.map(\.isVisible))
                XCTAssertEqual(fast.points.map(\.derivedFrom), boxed.points.map(\.derivedFrom))
                XCTAssertEqual(fast.points.count, 3)
            }
        }
    }

    func testRejectsUnsupportedDataTypeAndWrongModelChannelCount() throws {
        let geometry = try BottomLetterboxGeometry(originalSize: .init(width: 640, height: 640), orientation: .up)
        XCTAssertThrowsError(try CoreMLTensorReader.decode(tensor: tensor(dataType: .int32, strides: [56, 4, 1]),
                                                          schema: schema(), geometry: geometry))
        let wrong = try MLMultiArray(shape: [1, 13, 4], dataType: .float32)
        XCTAssertThrowsError(try CoreMLTensorReader.decode(tensor: wrong, schema: schema(), geometry: geometry))
    }

    func testLayoutValidationRejectsShortBuffersNegativeStridesAndIntegerOverflow() {
        let invalid: [([Int], [Int], Int, Int)] = [
            ([1, 14, 4], [56, 4, 1], 55 * 4, 4),
            ([1, 14, 4], [56, -4, 1], 56 * 4, 4),
            ([1, 14, 4], [56, Int.max, 1], Int.max, 4),
            ([1, 14, 4], [56, Int.max / 14, 1], Int.max, 8),
            ([2, 14, 4], [56, 4, 1], 112 * 4, 4),
            ([1, 14], [56, 4, 1], 56 * 4, 4),
            ([1, 14, 0], [56, 4, 1], 56 * 4, 4),
            ([1, 14, 4], [56, 4], 56 * 4, 4),
            ([1, 14, 4], [56, 4, 1], 56 * 4, 0)
        ]
        for (shape, strides, count, width) in invalid {
            XCTAssertThrowsError(try CoreMLTensorReader.validateLayout(shape: shape, strides: strides,
                                                                      byteCount: count, scalarByteWidth: width))
        }
    }

    func testPaddedBufferBoundsUseAddressableStrideExtentInsteadOfLogicalScalarCount() throws {
        // 56 logical elements, but the last padded element is at offset 110.
        XCTAssertNoThrow(try CoreMLTensorReader.validateLayout(shape: [1, 14, 4], strides: [120, 8, 2],
                                                              byteCount: 111 * 4, scalarByteWidth: 4))
        XCTAssertThrowsError(try CoreMLTensorReader.validateLayout(shape: [1, 14, 4], strides: [120, 8, 2],
                                                                  byteCount: 56 * 4, scalarByteWidth: 4))
    }
}
#endif
