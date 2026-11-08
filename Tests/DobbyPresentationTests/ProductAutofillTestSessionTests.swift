import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Dobby

/// All inputs are generated image bytes and all AI results are injected.
@MainActor
struct ProductAutofillTestSessionTests {
    @Test func importsActualMetadataAndSmallThumbnailsWithoutChangingInputBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.close() }
        let input = try image(width: 720, height: 480, orientation: 6)
        await session.replacePhotos([input, input])
        #expect(!session.isImporting && session.errorMessage == nil)
        #expect(session.photos.count == 2)
        let first = try #require(session.photos.first)
        let second = try #require(session.photos.last)
        #expect(first.asset.sessionID == second.asset.sessionID)
        #expect(first.asset.garmentID == second.asset.garmentID)
        #expect(first.asset.id != second.asset.id && first.id == first.asset.id)
        guard case let .localFile(url, metadata) = first.asset.source else {
            Issue.record("Expected a disposable imported file")
            return
        }
        #expect(try Data(contentsOf: url) == input)
        #expect(metadata.pixelWidth == 720 && metadata.pixelHeight == 480)
        #expect(metadata.contentType == "public.jpeg" && metadata.orientation == .right)
        let thumbnail = try #require(CGImageSourceCreateWithData(first.thumbnailData as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(thumbnail, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= 360)
        #expect(width < height, "The UI thumbnail applies EXIF orientation")
    }

    @Test func invalidReplacementKeepsPreviousPhotosAndGeneratedResultAndCleansNewFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        let bytes = try image()
        await session.replacePhotos([bytes])
        let oldPhoto = try #require(session.photos.first)
        session.start()
        await generator.waitForRequests(1)
        await generator.complete(0, with: generated("기존 테스트 결과"))
        await waitUntil { !session.isGenerating }
        let oldResult = try #require(session.result)
        let oldElapsed = session.elapsedSeconds
        await session.replacePhotos([bytes, Data("not-an-image".utf8)])
        #expect(session.photos.map(\.id) == [oldPhoto.id])
        #expect(session.result == oldResult && session.elapsedSeconds == oldElapsed)
        #expect(session.errorMessage != nil && !session.isImporting)
        let batches = try FileManager.default.contentsOfDirectory(at: session.directory, includingPropertiesForKeys: nil)
        #expect(batches.count == 1, "A partially written replacement batch is removed")
        #expect(try Data(contentsOf: fileURL(oldPhoto)) == bytes)
    }

    @Test func repeatedGenerationTapsSendOneRequestAndReturnDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        await session.replacePhotos([try image()])
        try #require(session.photos.count == 1)
        session.start()
        session.start()
        await generator.waitForRequests(1)
        #expect(session.isGenerating && session.result == nil)
        #expect(await generator.requestCount == 1)
        let expected = generated("테스트 결과")
        await generator.complete(0, with: expected)
        await waitUntil { !session.isGenerating }
        #expect(session.result == expected && session.errorMessage == nil)
        #expect(session.elapsedSeconds >= 0)
        #expect(await generator.requestCount == 1)
    }

    @Test func successfulPhotoReplacementCancelsOldRequestAndRejectsItsLateResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        await session.replacePhotos([try image()])
        let oldPhoto = try #require(session.photos.first)
        session.start()
        await generator.waitForRequests(1)
        await session.replacePhotos([try image(width: 320, height: 240)])
        #expect(!session.isGenerating && session.result == nil && session.elapsedSeconds == 0)
        #expect(!FileManager.default.fileExists(atPath: try fileURL(oldPhoto).path))
        session.start()
        await generator.waitForRequests(2)
        await generator.complete(0, with: generated("늦게 도착한 이전 사진 결과"))
        #expect(session.result == nil && session.isGenerating)
        await generator.complete(1, with: generated("새 사진 결과"))
        await waitUntil { !session.isGenerating }
        #expect(session.result?.draft.productName == "새 사진 결과")
    }

    @Test func cancellingAndClosingNeverPublishLateResultsOrDeleteAnotherSessionFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        let other = fixture.session()
        defer { other.close() }
        await session.replacePhotos([try image()])
        await other.replacePhotos([try image()])
        let otherPhoto = try #require(other.photos.first)
        session.start()
        await generator.waitForRequests(1)
        session.cancel()
        #expect(!session.isGenerating && session.result == nil)
        session.close()
        await generator.complete(0, with: generated("닫은 뒤 결과"))
        await Task.yield()
        #expect(session.photos.isEmpty && session.result == nil)
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
        #expect(FileManager.default.fileExists(atPath: try fileURL(otherPhoto).path))
        #expect(FileManager.default.fileExists(atPath: fixture.unrelated.path))
        await session.replacePhotos([try image()])
        session.start()
        #expect(await generator.requestCount == 1, "A closed test session cannot restart")
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
    }

    @Test func removingAndClearingPhotosResetsResultsAndOnlyRemovesOwnedTemporaryCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        await session.replacePhotos([try image(), try image()])
        let first = try #require(session.photos.first)
        let second = try #require(session.photos.last)
        session.start()
        await generator.waitForRequests(1)
        await generator.complete(0, with: generated("삭제 전 결과"))
        await waitUntil { !session.isGenerating }
        session.removePhoto(first.id)
        #expect(session.photos.map(\.id) == [second.id])
        #expect(session.result == nil && session.elapsedSeconds == 0)
        #expect(!FileManager.default.fileExists(atPath: try fileURL(first).path))
        #expect(FileManager.default.fileExists(atPath: try fileURL(second).path))
        session.clear()
        #expect(session.photos.isEmpty && !session.isGenerating && !session.isImporting)
        #expect(!FileManager.default.fileExists(atPath: session.directory.path))
        #expect(FileManager.default.fileExists(atPath: fixture.unrelated.path))
    }

    @Test func countAndByteLimitsDoNotReplaceValidPhotosOrStartAIRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        let bytes = try image()
        await session.replacePhotos([bytes])
        let ids = session.photos.map(\.id)
        for invalid in [[], Array(repeating: bytes, count: 6), [Data()], [Data(repeating: 0, count: 20 * 1024 * 1024 + 1)]] {
            await session.replacePhotos(invalid)
            #expect(session.photos.map(\.id) == ids)
            #expect(session.errorMessage != nil && !session.isImporting)
        }
        #expect(await generator.requestCount == 0)
    }

    @Test func noPhotosAndFailedGenerationStayEditableWithoutAutomaticRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generator = TestSessionGenerator()
        let session = fixture.session(generator: generator)
        defer { session.close() }
        session.start()
        #expect(session.errorMessage != nil && !session.isGenerating)
        #expect(await generator.requestCount == 0)
        await session.replacePhotos([try image()])
        session.start()
        await generator.waitForRequests(1)
        await generator.fail(0)
        await waitUntil { !session.isGenerating }
        #expect(session.result == nil && session.photos.count == 1)
        #expect(session.errorMessage == ProductAutofillError.offline.localizedDescription)
        #expect(await generator.requestCount == 1)
    }

    private func generated(_ name: String) -> ProductAutofillGenerationResult {
        let response = HTTPURLResponse(url: URL(string: "https://example.com/ai-test")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["X-Dobby-AI-Search-Calls": "1",
                "X-Dobby-AI-Search-Attempts": "1", "X-Dobby-AI-Research-Status": "matched",
                "X-Request-Id": UUID().uuidString])!
        return .init(draft: .init(productName: name, brand: "TEST", description: "확인된 테스트 설명입니다.", reviewNotes: []),
            diagnostics: .init(response: response))
    }

    private func fileURL(_ photo: ProductAutofillTestPhoto) throws -> URL {
        guard case let .localFile(url, _) = photo.asset.source else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    private func image(width: Int = 64, height: Int = 48, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The injected request did not finish")
    }

    private struct Fixture {
        let directory: URL
        let unrelated: URL
        init() throws {
            directory = URL.temporaryDirectory.appending(path: "dobby-ai-test-session-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            unrelated = directory.appending(path: "unrelated.txt")
            try Data("retained".utf8).write(to: unrelated)
        }
        func session(generator: (any ProductAutofillGenerating)? = nil) -> ProductAutofillTestSession {
            ProductAutofillTestSession(generator: generator ?? TestSessionGenerator(), directory: directory)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Deliberately ignores cancellation until released to test stale completion guards.
private actor TestSessionGenerator: ProductAutofillGenerating {
    private var requests: [[CapturedAsset]] = []
    private var pending: [Int: CheckedContinuation<ProductAutofillGenerationResult, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var requestCount: Int { requests.count }

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        try await generateWithDiagnostics(photos: photos).draft
    }

    func generateWithDiagnostics(photos: [CapturedAsset]) async throws -> ProductAutofillGenerationResult {
        let index = requests.count
        requests.append(photos)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func complete(_ index: Int, with result: ProductAutofillGenerationResult) { pending.removeValue(forKey: index)?.resume(returning: result) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: ProductAutofillError.offline) }
}
