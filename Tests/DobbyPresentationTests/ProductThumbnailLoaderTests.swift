import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Dobby

@MainActor
final class ProductThumbnailLoaderTests: XCTestCase {
    func testThumbnailBoundsAndEXIFOrientationPreserveTheOriginalFile() async throws {
        let url = temporaryJPEGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJPEG(to: url, orientation: 6)
        let originalBytes = try Data(contentsOf: url)
        let loader = ProductThumbnailLoader()
        let decoded = await loader.image(for: .init(url: url, maximumPixelSize: 60))
        let image = try XCTUnwrap(decoded?.image)
        XCTAssertEqual(image.width, 30)
        XCTAssertEqual(image.height, 60, "The thumbnail must bake in the original JPEG's EXIF rotation")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testConcurrentEqualRequestsDecodeOnceOutsideTheUIActor() async throws {
        let probe = DecodeProbe(thumbnail: try smallThumbnail())
        let loader = ProductThumbnailLoader(decoder: { _, limit in probe.decode(limit: limit) })
        let request = ProductThumbnailRequest(url: temporaryJPEGURL(), maximumPixelSize: 320)
        let thumbnails = await withTaskGroup(of: ProductThumbnail?.self, returning: [ProductThumbnail].self) { group in
            for _ in 0..<8 { group.addTask { await loader.image(for: request) } }
            var images: [ProductThumbnail] = []
            for await image in group { if let image { images.append(image) } }
            return images
        }
        XCTAssertEqual(thumbnails.count, 8)
        XCTAssertEqual(probe.limits, [320], "Queued equal requests should reuse the completed decode")
        XCTAssertFalse(probe.ranOnMainThread)
        let first = try XCTUnwrap(thumbnails.first)
        XCTAssertTrue(thumbnails.allSatisfy { $0 === first })
    }

    func testOversizeRasterIsReturnedWithoutExceedingTheCacheBudget() async throws {
        let probe = DecodeProbe(thumbnail: try smallThumbnail())
        let loader = ProductThumbnailLoader(maximumCachedBytes: 1,
            decoder: { _, limit in probe.decode(limit: limit) })
        let request = ProductThumbnailRequest(url: temporaryJPEGURL(), maximumPixelSize: 320)
        let first = await loader.image(for: request)
        let second = await loader.image(for: request)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(probe.limits, [320, 320], "An image larger than the budget must not enter the cache")
    }

    func testInvalidRequestsAreRejectedAndRequestedDecodeSizeIsBounded() async throws {
        let probe = DecodeProbe(thumbnail: try smallThumbnail())
        let loader = ProductThumbnailLoader(decoder: { _, limit in probe.decode(limit: limit) })
        let url = temporaryJPEGURL()
        let zero = await loader.image(for: .init(url: url, maximumPixelSize: 0))
        let negative = await loader.image(for: .init(url: url, maximumPixelSize: -1))
        let remote = await loader.image(for: .init(url: URL(string: "https://example.invalid/photo.jpg")!,
                                                  maximumPixelSize: 320))
        let oversized = await loader.image(for: .init(url: url, maximumPixelSize: Int.max))
        XCTAssertNil(zero)
        XCTAssertNil(negative)
        XCTAssertNil(remote)
        XCTAssertNotNil(oversized)
        XCTAssertEqual(probe.limits, [4096])
    }

    func testCancellationDuringARealWorkerSuppressesItsLateImage() async throws {
        let gate = DecodeGate(thumbnail: try smallThumbnail())
        defer { gate.release() }
        let loader = ProductThumbnailLoader(decoder: { _, _ in gate.decode() })
        let request = ProductThumbnailRequest(url: temporaryJPEGURL(), maximumPixelSize: 320)
        let task = Task { await loader.image(for: request) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !gate.hasStarted && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(gate.hasStarted)
        task.cancel()
        gate.release()
        let image = await task.value
        XCTAssertNil(image, "A decoder that completes after cancellation must not publish a late image")
    }

    func testMissingFileDoesNotPoisonALaterValidRequest() async throws {
        let url = temporaryJPEGURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let loader = ProductThumbnailLoader()
        let request = ProductThumbnailRequest(url: url, maximumPixelSize: 60)
        let missing = await loader.image(for: request)
        XCTAssertNil(missing)
        try writeJPEG(to: url, orientation: 1)
        let decoded = await loader.image(for: request)
        XCTAssertEqual(decoded?.image.width, 60)
        XCTAssertEqual(decoded?.image.height, 30)
    }

    private func temporaryJPEGURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("product-thumbnail-\(UUID()).jpg")
    }

    private func smallThumbnail() throws -> ProductThumbnail {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return ProductThumbnail(image: try XCTUnwrap(context.makeImage()))
    }

    private func writeJPEG(to url: URL, orientation: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8,
            bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private nonisolated final class DecodeProbe: @unchecked Sendable {
    let thumbnail: ProductThumbnail
    private let lock = NSLock()
    private var recordedLimits: [Int] = []
    private var recordedMainThread = false

    init(thumbnail: ProductThumbnail) { self.thumbnail = thumbnail }

    var limits: [Int] {
        lock.lock(); defer { lock.unlock() }
        return recordedLimits
    }

    var ranOnMainThread: Bool {
        lock.lock(); defer { lock.unlock() }
        return recordedMainThread
    }

    func decode(limit: Int) -> ProductThumbnail {
        lock.lock(); defer { lock.unlock() }
        recordedLimits.append(limit)
        recordedMainThread = recordedMainThread || Thread.isMainThread
        return thumbnail
    }
}

private nonisolated final class DecodeGate: @unchecked Sendable {
    let thumbnail: ProductThumbnail
    private let condition = NSCondition()
    private var started = false
    private var released = false

    init(thumbnail: ProductThumbnail) { self.thumbnail = thumbnail }

    var hasStarted: Bool {
        condition.lock(); defer { condition.unlock() }
        return started
    }

    func decode() -> ProductThumbnail {
        condition.lock(); defer { condition.unlock() }
        started = true
        while !released { condition.wait() }
        return thumbnail
    }

    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
