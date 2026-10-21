// Created by mason on 10/21/26.
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Dobby

final class DetailPhotoProcessorTests: XCTestCase {
    private let colors: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 255]]
    private func photo(orientation: Int = 1) throws -> Data {
        let bytes = (0..<80 * 48).flatMap { colors[($0 / 80 < 24 ? 0 : 2) + ($0 % 80 < 40 ? 0 : 1)] }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 80, height: 48, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    func testUnspecifiedRatioPreservesOriginalBytesAndOrientation() async throws {
        let original = try photo(orientation: 6)
        let output = try await DetailPhotoProcessor().process(original, aspectRatio: nil)
        XCTAssertEqual(output, original)
    }
    func testEightOrientationsArePhysicallyNormalizedIncludingMirrors() async throws {
        let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                        [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
        let processor = DetailPhotoProcessor()
        for orientation in 1...8 {
            let output = try await processor.process(photo(orientation: orientation), aspectRatio: .fourThree)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            // ImageIO는 정상 방향(1)을 생략할 수 있다. 픽셀 방향은 아래 사분면 검사로 별도 검증한다.
            XCTAssertEqual(metadata[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            XCTAssertEqual(image.width, orientation >= 5 ? 48 : 64)
            XCTAssertEqual(image.height, orientation >= 5 ? 64 : 48)
            for index in 0..<4 {
                let sample = try XCTUnwrap(image.cropping(to: CGRect(x: image.width * (index % 2 == 0 ? 1 : 3) / 4,
                    y: image.height * (index < 2 ? 1 : 3) / 4, width: 1, height: 1)))
                var pixel = [UInt8](repeating: 0, count: 4)
                try pixel.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                for channel in 0..<3 {
                    XCTAssertEqual(Double(pixel[channel]), Double(colors[expected[orientation - 1][index]][channel]), accuracy: 30)
                }
            }
        }
    }
    func testProcessedDimensionsAndIdentityReachStoreAndDiscardOnlyOwnFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraPhotoStore(directory: root), processor = DetailPhotoProcessor()
        let session = UUID(), garment = UUID(), date = Date(timeIntervalSince1970: 123)
        var urls: [URL] = []
        for (ratio, width, height) in [(DetailPhotoAspectRatio.sixteenNine, 80, 45), (.square, 48, 48)] {
            let output = try await processor.process(photo(), aspectRatio: ratio)
            let asset = try await store.save(output, sessionID: session, garmentID: garment, capturedAt: date)
            XCTAssertEqual(asset.sessionID, session); XCTAssertEqual(asset.garmentID, garment)
            XCTAssertEqual(asset.capturedAt, date)
            guard case let .localFile(url, metadata) = asset.source else { return XCTFail("저장 파일 없음") }
            XCTAssertEqual(metadata.pixelWidth, width); XCTAssertEqual(metadata.pixelHeight, height)
            XCTAssertEqual(metadata.orientation, .up)
            XCTAssertEqual(try Data(contentsOf: url), output)
            if ratio == .square { try await store.discardUncommitted(asset) }
            urls.append(url)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
    }
    func testInvalidInputAndCancelledProcessingNeverProduceOutput() async throws {
        do {
            _ = try await DetailPhotoProcessor().process(Data([0, 1]), aspectRatio: .square)
            XCTFail("손상된 사진을 처리하면 안 됩니다.")
        } catch { XCTAssertEqual(error as? CameraFailure, .saveFailed) }
        let data = try photo()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DetailPhotoProcessor().process(data, aspectRatio: .square)
        }
        do { _ = try await task.value; XCTFail("취소된 처리 결과가 반환됐습니다.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testStorageFailureDoesNotCreatePhotoFile() async throws {
        let blocked = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([7]).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let output = try await DetailPhotoProcessor().process(photo(), aspectRatio: .square)
        do {
            _ = try await CameraPhotoStore(directory: blocked).save(output, sessionID: UUID(), garmentID: UUID(), capturedAt: .now)
            XCTFail("저장소가 파일이면 저장에 실패해야 합니다.")
        } catch { XCTAssertEqual(error as? CameraFailure, .saveFailed) }
        XCTAssertEqual(try Data(contentsOf: blocked), Data([7]))
    }
}
