import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Dobby

@MainActor
final class ProductAutofillClientTests: XCTestCase {
    func testMissingAuthorizationStopsBeforeReadingPhotosOrSendingRequest() async throws {
        let client = ProductAutofillClient(bearerTokenProvider: { nil })
        do {
            _ = try await client.generate(photos: [])
            XCTFail("인증 없는 요청이 전송되면 안 됩니다.")
        } catch { XCTAssertEqual(error as? ProductAutofillError, .notConfigured) }
    }

    func testUploadUsesFirstFiveInSelectionOrderAndPreservesParagraphsAndNullBrand() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 7, directory: directory)
        let draft = ProductAutofillDraft(productName: "네이비 후드", brand: nil,
            description: "첫 문단입니다.\n\n두 번째 문단입니다.", reviewNotes: ["브랜드 라벨 확인 필요"])
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft))
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            bearerTokenProvider: { "ui-test-authorization" })
        let result = try await client.generate(photos: photos)
        XCTAssertEqual(result, draft)
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ui-test-authorization")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let sent = try XCTUnwrap(object["photos"] as? [[String: String]])
        XCTAssertEqual(sent.map { $0["id"] }, photos.prefix(5).map { Optional($0.id.uuidString) })
        XCTAssertEqual(sent.map { $0["role"] }, Array(repeating: "detail", count: 5))
        XCTAssertTrue(sent.allSatisfy { $0["imageDataUrl"]?.hasPrefix("data:image/jpeg;base64,") == true })
        XCTAssertEqual(stub.requestCount, 1, "성공이나 실패를 자동으로 재요청하지 않는다")
        XCTAssertEqual(photos.count, 7, "AI 전송 제한이 제품 사진을 줄이면 안 된다")
    }

    func testKnownServerCodesBecomeSafeErrorsWithoutAutomaticRetry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 1, directory: directory)
        for (status, code, expected) in [
            (401, "unauthorized", ProductAutofillError.unauthorized),
            (422, "photo_unusable", .photoUnusable),
            (503, "ai_rate_limited", .busy),
            (503, "ai_configuration_error", .serverNotConfigured),
            (504, "ai_timeout", .timeout),
            (502, "unknown", .serverUnavailable)
        ] {
            let body = Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"untrusted server message\"}}".utf8)
            let stub = AutofillHTTPStub(status: status, body: body)
            defer { stub.remove() }
            let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
                bearerTokenProvider: { "ui-test-authorization" })
            do {
                _ = try await client.generate(photos: photos)
                XCTFail("실패 상태를 성공으로 반환하면 안 됩니다.")
            } catch {
                XCTAssertEqual(error as? ProductAutofillError, expected)
                XCTAssertFalse(error.localizedDescription.contains("untrusted server message"))
            }
            XCTAssertEqual(stub.requestCount, 1)
        }
    }

    func testMalformedOrOversizedDraftIsNeverReturnedForApplying() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 1, directory: directory)
        for data in [Data("{}".utf8), Data(repeating: 65, count: 64 * 1024 + 1),
                     try JSONEncoder().encode(ProductAutofillDraft(productName: "", brand: nil,
                        description: "설명", reviewNotes: []))] {
            let stub = AutofillHTTPStub(status: 200, body: data)
            defer { stub.remove() }
            let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
                bearerTokenProvider: { "ui-test-authorization" })
            do { _ = try await client.generate(photos: photos); XCTFail("잘못된 응답이 적용되면 안 됩니다.") }
            catch { XCTAssertEqual(error as? ProductAutofillError, .invalidResponse) }
        }
    }

    func testJPEGUploadNormalizesAllExifOrientationsAndLeavesOriginalUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expected = [[0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
                        [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]]
        for orientation in 1...8 {
            let original = try imageData(width: 80, height: 48, orientation: orientation)
            let url = directory.appending(path: "orientation-\(orientation).jpg")
            try original.write(to: url)
            let asset = makePhoto(url: url, orientation: orientation)
            let encoded = try XCTUnwrap(ProductAutofillPhotoEncoder.encode([asset]).first)
            let base64 = String(encoded.imageDataUrl.dropFirst("data:image/jpeg;base64,".count))
            let data = try XCTUnwrap(Data(base64Encoded: base64))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(image.width, orientation >= 5 ? 48 : 80)
            XCTAssertEqual(image.height, orientation >= 5 ? 80 : 48)
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            XCTAssertEqual(try Data(contentsOf: url), original)
            let rawSource = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
            let rawImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(rawSource, 0, nil))
            for quadrant in 0..<4 {
                let actual = try pixel(in: image, quadrant: quadrant)
                let originalPixel = try pixel(in: rawImage, quadrant: expected[orientation - 1][quadrant])
                for channel in 0..<3 {
                    XCTAssertEqual(Double(actual[channel]), Double(originalPixel[channel]), accuracy: 35,
                        "EXIF \(orientation) 방향의 사분면 \(quadrant)")
                }
            }
        }
    }

    func testLargePhotoIsDownsampledAndAggregateBudgetAndIdentifiersArePreserved() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.jpg")
        try imageData(width: 4096, height: 3072).write(to: url)
        let session = UUID(), garment = UUID()
        let photos = (0..<5).map { _ in makePhoto(url: url, session: session, garment: garment) }
        let encoded = try ProductAutofillPhotoEncoder.encode(photos)
        var total = 0
        for photo in encoded {
            let data = try XCTUnwrap(Data(base64Encoded: String(photo.imageDataUrl.dropFirst("data:image/jpeg;base64,".count))))
            total += data.count
            XCTAssertLessThanOrEqual(data.count, ProductAutofillPhotoEncoder.maximumPhotoBytes)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertLessThanOrEqual(max(image.width, image.height), 2048)
        }
        XCTAssertLessThanOrEqual(total, ProductAutofillPhotoEncoder.maximumTotalBytes)
        XCTAssertEqual(encoded.map(\.id), photos.map { $0.id.uuidString })
    }

    func testEncoderRejectsMissingFilesDuplicateIdentifiersAndMixedProducts() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 2, directory: directory)
        XCTAssertThrowsError(try ProductAutofillPhotoEncoder.encode([]))
        XCTAssertThrowsError(try ProductAutofillPhotoEncoder.encode([photos[0], photos[0]]))
        let foreign = makePhoto(url: directory.appending(path: "0.jpg"))
        XCTAssertThrowsError(try ProductAutofillPhotoEncoder.encode([photos[0], foreign]))
        let missing = makePhoto(url: directory.appending(path: "missing.jpg"))
        XCTAssertThrowsError(try ProductAutofillPhotoEncoder.encode([missing]))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePhotos(count: Int, directory: URL) throws -> [CapturedAsset] {
        let session = UUID(), garment = UUID()
        return try (0..<count).map { index in
            let url = directory.appending(path: "\(index).jpg")
            try imageData(width: 80, height: 48).write(to: url)
            return makePhoto(url: url, session: session, garment: garment)
        }
    }

    private func makePhoto(url: URL, orientation: Int = 1, session: UUID = UUID(), garment: UUID = UUID()) -> CapturedAsset {
        CapturedAsset(id: UUID(), sessionID: session, garmentID: garment, purpose: .detail,
            capturedAt: .now, source: .localFile(url, metadata: .init(pixelWidth: 80, pixelHeight: 48,
                contentType: "public.jpeg", orientation: .init(rawValue: orientation)!)))
    }

    private func imageData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 1, blue: 0, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 1),
                      CGColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for index in 0..<4 {
            context.setFillColor(colors[index])
            context.fill(CGRect(x: index % 2 * width / 2, y: index / 2 * height / 2,
                width: width / 2, height: height / 2))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.0]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixel(in image: CGImage, quadrant: Int) throws -> [UInt8] {
        let crop = try XCTUnwrap(image.cropping(to: CGRect(
            x: image.width * (quadrant % 2 == 0 ? 1 : 3) / 4,
            y: image.height * (quadrant < 2 ? 1 : 3) / 4, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}

private nonisolated final class AutofillHTTPStub: @unchecked Sendable {
    let endpoint = URL(string: "https://autofill-test.invalid/" + UUID().uuidString)!
    let status: Int
    let body: Data
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var request: URLRequest? { lock.withLock { requests.last } }
    var requestCount: Int { lock.withLock { requests.count } }
    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutofillURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    init(status: Int, body: Data) {
        self.status = status
        self.body = body
        AutofillURLProtocol.register(self)
    }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func remove() { AutofillURLProtocol.remove(endpoint) }
}

private nonisolated final class AutofillURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [URL: AutofillHTTPStub] = [:]
    static func register(_ stub: AutofillHTTPStub) { lock.withLock { stubs[stub.endpoint] = stub } }
    static func remove(_ url: URL) { lock.withLock { _ = stubs.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "autofill-test.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let stub = Self.lock.withLock({ Self.stubs[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        stub.record(captured)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
