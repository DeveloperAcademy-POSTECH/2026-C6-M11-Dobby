// Created by mason on 10/21/26.
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Dobby

@MainActor
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

    // Created by mason on 10/23/26. 제어기는 목, 크롭·JPEG·저장소는 실제 구현이다.
    func testOptionsRecoveryAndAllRatiosReachSavedPhotosWithoutRewritingEarlierFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controls = RecoveringDetailControls()
        let options = DetailCameraOptions(controller: controls)
        let processor = DetailPhotoProcessor(), store = CameraPhotoStore(directory: root)
        let session = UUID(), garment = UUID()
        let original = try photo(orientation: 6)
        var saved: [(URL, Data)] = []
        await options.refreshCapabilities()
        await options.apply(.exposure(0.5))
        for ratio in DetailPhotoAspectRatio.allCases {
            options.photoAspectRatio = ratio
            await controls.failNextZoom()
            await options.apply(.zoom(2))
            XCTAssertEqual(options.failure, .deviceFailure)
            XCTAssertEqual(options.appliedExposure, 0.5)
            XCTAssertFalse(options.isApplying)
            await options.apply(.zoom(2))
            XCTAssertNil(options.failure)
            XCTAssertEqual(options.appliedZoom, 2)

            // 중단/복귀 시 Model 경계: 비율은 유지하고 장치가 보고한 값을 다시 읽는다.
            options.invalidate()
            XCTAssertNil(options.appliedZoom)
            await options.refreshCapabilities()
            XCTAssertEqual(options.photoAspectRatio, ratio)
            XCTAssertEqual(options.appliedExposure, 0.5)
            XCTAssertEqual(options.appliedZoom, 2)
            let data = try await processor.process(original, aspectRatio: options.photoAspectRatio)
            let asset = try await store.save(data, sessionID: session, garmentID: garment, capturedAt: .now)
            guard case let .localFile(url, metadata) = asset.source else { return XCTFail("저장 파일 없음") }
            XCTAssertEqual(asset.sessionID, session)
            XCTAssertEqual(asset.garmentID, garment)
            XCTAssertEqual(asset.purpose, .detail)
            XCTAssertEqual(metadata.orientation, .up)
            XCTAssertEqual(Double(metadata.pixelWidth) / Double(metadata.pixelHeight),
                           ratio.previewRatio(isLandscape: false), accuracy: 0.0001)
            saved.append((url, data))
        }
        XCTAssertEqual(Set(saved.map { $0.0 }).count, 3)
        for (url, bytes) in saved { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        XCTAssertEqual(try photo(orientation: 6), original)
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
    func testPreviewCropReachesJPEGAfterExifRotation() async throws {
        let output = try await DetailPhotoProcessor().process(photo(orientation: 6), aspectRatio: .square,
            normalizedPreviewCrop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 24)
        XCTAssertEqual(image.height, 24)
        let center = try XCTUnwrap(image.cropping(to: CGRect(x: 12, y: 12, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        // 원본 좌하단의 파란 영역이 EXIF 6 회전 후 좌상단에 온다.
        XCTAssertLessThan(rgba[0], 30)
        XCTAssertLessThan(rgba[1], 30)
        XCTAssertGreaterThan(rgba[2], 225)
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

    func testUnspecifiedRatioSurvivesStorageWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try photo(orientation: 6)
        let output = try await DetailPhotoProcessor().process(original, aspectRatio: nil)
        let asset = try await CameraPhotoStore(directory: root).save(output,
            sessionID: UUID(), garmentID: UUID(), capturedAt: .now)
        guard case let .localFile(url, metadata) = asset.source else { return XCTFail("저장 파일 없음") }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(metadata.pixelWidth, 80)
        XCTAssertEqual(metadata.pixelHeight, 48)
        XCTAssertEqual(metadata.orientation, .right)
    }

    func testCancelledOrInvalidSaveDoesNotCreateDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraPhotoStore(directory: root), data = try photo()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(data, sessionID: UUID(), garmentID: UUID(), capturedAt: .now)
        }
        do { _ = try await task.value; XCTFail("취소된 저장이 완료됐습니다.") }
        catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await store.save(Data([0, 1]), sessionID: UUID(), garmentID: UUID(), capturedAt: .now)
            XCTFail("손상된 입력이 저장됐습니다.")
        } catch { XCTAssertEqual(error as? CameraFailure, .saveFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDiscardRejectsMeasurementAndForeignAssetAndIsRepeatable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CameraPhotoStore(directory: root)
        let original = try photo()
        let asset = try await store.save(original, sessionID: UUID(), garmentID: UUID(), capturedAt: .now)
        guard case let .localFile(url, _) = asset.source else { return XCTFail("저장 파일 없음") }
        for (purpose, session) in [(CapturedAsset.Purpose.measurement, asset.sessionID), (.detail, UUID())] {
            let protected = CapturedAsset(id: asset.id, sessionID: session, garmentID: asset.garmentID,
                purpose: purpose, capturedAt: asset.capturedAt, source: asset.source)
            do { try await store.discardUncommitted(protected); XCTFail("보호된 사진이 삭제됐습니다.") }
            catch { XCTAssertEqual(error as? CameraFailure, .saveFailed) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        try await store.discardUncommitted(asset)
        try await store.discardUncommitted(asset)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private actor RecoveringDetailControls: DetailCameraControlling {
    private var exposure = 0.0, zoom = 1.0
    private var shouldFailZoom = false
    func failNextZoom() { shouldFailZoom = true }
    func capabilities() async throws -> DetailCameraCapabilities {
        .init(exposure: .init(minimum: -2, maximum: 2), zoom: .init(minimum: 0.5, maximum: 2),
              exposureBias: exposure, zoomFactor: zoom)
    }
    func apply(_ request: DetailCameraControlRequest) async throws -> Double {
        switch request {
        case .exposure(let value): exposure = value; return value
        case .zoom(let value):
            if shouldFailZoom {
                shouldFailZoom = false
                throw DetailCameraControlFailure.deviceFailure
            }
            zoom = value
            return value
        }
    }
}
