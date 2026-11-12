import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Dobby

@MainActor
final class ProductAutofillClientTests: XCTestCase {
    func testProductFlowDefaultUsesWebPipelineWithoutLaunchFlag() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 3, directory: directory)
        let draft = ProductAutofillDraft(productName: "그래픽 긴팔 티셔츠", brand: nil,
            description: "- 등판에 식당 그래픽이 있습니다.", reviewNotes: [])
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft), endpoint: ProductAutofillEndpoints.generation)
        defer { stub.remove() }
        let client = ProductAutofillClient(session: stub.session, bearerTokenProvider: { "fixture-token" })
        let result = try await client.generate(photos: photos)
        XCTAssertEqual(result, draft)
        XCTAssertEqual(stub.request?.url?.path, "/v1/garments/autofill-web-detection")
        XCTAssertEqual(stub.requestCount, 1)
        let body = try XCTUnwrap(stub.request?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["labelCrops"])
    }

    func testWebDetectionRequestSkipsOCRPreflightAndKeepsStandardPhotoBudget() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 5, directory: directory)
        let endpoint = URL(string: "https://autofill-test.invalid/v1/garments/autofill-web-detection")!
        let draft = ProductAutofillDraft(productName: "데님 셔츠", brand: "CLIQUE",
            description: "- 스냅 버튼과 가슴 자수", reviewNotes: [])
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft), endpoint: endpoint)
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: endpoint, session: stub.session,
            bearerTokenProvider: { "fixture-token" })
        let result = try await client.generate(photos: photos)
        XCTAssertEqual(result, draft)
        XCTAssertEqual(stub.requestCount, 1)
        let body = try XCTUnwrap(stub.request?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["labelCrops"])
        let uploaded = try XCTUnwrap(json["photos"] as? [[String: String]])
        XCTAssertEqual(uploaded.count, 5)
        XCTAssertEqual(uploaded.compactMap { $0["id"] }, photos.map { $0.id.uuidString })
        for photo in uploaded {
            let dataURL = try XCTUnwrap(photo["imageDataUrl"])
            let data = try XCTUnwrap(Data(base64Encoded: String(dataURL.split(separator: ",")[1])))
            XCTAssertLessThanOrEqual(data.count, ProductAutofillPhotoEncoder.maximumPhotoBytes)
        }
        XCTAssertEqual(stub.request?.timeoutInterval, 95)
    }

    func testWebDetectionDiagnosticsAcceptTwoSearchesAndSeparateStages() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://autofill-test.invalid/")!,
            statusCode: 200, httpVersion: nil, headerFields: [
                "X-Dobby-AI-Search-Calls": "2", "X-Dobby-AI-Web-Detection-Ms": "12000",
                "X-Dobby-AI-Synthesis-Ms": "8000", "X-Dobby-AI-Brand-Reason": "web_detection_photo_comparison",
            ]))
        let activity = try XCTUnwrap(ProductAutofillDiagnostics.SearchActivity.read(response))
        XCTAssertEqual(activity.completedCalls, 2)
        XCTAssertEqual(activity.serverTimings?["Web-Detection"], 12000)
        XCTAssertEqual(activity.serverTimings?["Synthesis"], 8000)
        XCTAssertEqual(activity.brandReason, "web_detection_photo_comparison")
    }

    func testLabelProcessUsesSameAuthorizationAndContinuesWithEmptyBrandEvidenceWhenNoRegionExists() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpoint = URL(string: "https://autofill-test.invalid/v1/garments/autofill-labels")!
        let locationURL = endpoint.deletingLastPathComponent().appendingPathComponent("brand-label-regions")
        let location = AutofillHTTPStub(status: 200, body: Data("{\"regions\":[]}".utf8), endpoint: locationURL)
        let draft = ProductAutofillDraft(productName: "테스트 상의", brand: nil, description: "- 긴소매 상의", reviewNotes: [])
        let final = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft), endpoint: endpoint)
        defer { location.remove(); final.remove() }
        let client = ProductAutofillClient(endpoint: endpoint, session: final.session, bearerTokenProvider: { "fixture-token" })
        let result = try await client.generate(photos: makePhotos(count: 1, directory: directory))
        XCTAssertEqual(result, draft)
        XCTAssertEqual(location.requestCount, 1)
        XCTAssertEqual(final.requestCount, 1)
        XCTAssertEqual(location.request?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        let body = try XCTUnwrap(final.request?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["labelCrops"] as? [Any])?.count, 0)
    }

    func testBrandDecisionAndOverlappingServerStageTimesAreRecordedFromAllowlistedHeaders() throws {
        let url = URL(string: "https://autofill-test.invalid/diagnostic")!
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "X-Dobby-AI-Identification-Ms": "8000", "X-Dobby-AI-Label-Read-Ms": "6000",
            "X-Dobby-AI-Search-Ms": "9000", "X-Dobby-AI-Server-Ms": "17500",
            "X-Dobby-AI-Brand-Status": "unverified", "X-Dobby-AI-Brand-Reason": "ocr_mismatch",
        ]))
        let activity = try XCTUnwrap(ProductAutofillDiagnostics.SearchActivity.read(response))
        XCTAssertEqual(activity.serverTimings?["Label-Read"], 6000)
        XCTAssertEqual(activity.serverTimings?["Server"], 17500)
        XCTAssertEqual(activity.brandStatus, "unverified")
        XCTAssertEqual(activity.brandReason, "ocr_mismatch")
        let malformed = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "X-Dobby-AI-Search-Calls": "1", "X-Dobby-AI-Label-Read-Ms": "nan",
            "X-Dobby-AI-Brand-Status": "unverified", "X-Dobby-AI-Brand-Reason": "arbitrary upstream message",
        ]))
        let filtered = try XCTUnwrap(ProductAutofillDiagnostics.SearchActivity.read(malformed))
        XCTAssertNil(filtered.serverTimings)
        XCTAssertNil(filtered.brandReason)
    }

    func testMissingAuthorizationStopsBeforeReadingPhotosOrSendingRequest() async throws {
        let stub = AutofillHTTPStub(status: 200, body: Data())
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            bearerTokenProvider: { nil })
        do {
            _ = try await client.generate(photos: [])
            XCTFail("인증 없는 요청이 전송되면 안 됩니다.")
        } catch { XCTAssertEqual(error as? ProductAutofillError, .notConfigured) }
        XCTAssertEqual(stub.requestCount, 0)
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
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Dobby-App-Key"),
                     "The legacy initializer retains its original Bearer-only contract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let sent = try XCTUnwrap(object["photos"] as? [[String: String]])
        XCTAssertEqual(sent.map { $0["id"] }, photos.prefix(5).map { Optional($0.id.uuidString) })
        XCTAssertEqual(sent.map { $0["role"] }, Array(repeating: "detail", count: 5))
        XCTAssertTrue(sent.allSatisfy { $0["imageDataUrl"]?.hasPrefix("data:image/jpeg;base64,") == true })
        XCTAssertEqual(stub.requestCount, 1, "성공이나 실패를 자동으로 재요청하지 않는다")
        XCTAssertEqual(photos.count, 7, "AI 전송 제한이 제품 사진을 줄이면 안 된다")
    }

    func testSearchMetadataHeadersDoNotChangeOrdinaryDraftOrAddRequests() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = ProductAutofillDraft(productName: "연결 테스트 후드", brand: nil,
            description: "- 긴소매 후드", reviewNotes: [])
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft), headers: [
            "X-Dobby-AI-Search-Calls": "1", "X-Dobby-AI-Search-Attempts": "1",
            "X-Dobby-AI-Research-Status": "matched",
        ])
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            bearerTokenProvider: { "test-only-authorization" })

        let result = try await client.generate(photos: makePhotos(count: 1, directory: directory))
        XCTAssertEqual(result, draft)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testCommonAuthorizationAddsAppKeyAndInstallationBearerToTheExistingRequest() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 2, directory: directory)
        let draft = ProductAutofillDraft(productName: "공통 인증 테스트 후드", brand: nil,
            description: "첫 문단입니다.\n\n두 번째 문단입니다.", reviewNotes: [])
        let appKey = "unit-test-common-app-key"
        let owner = String(repeating: "ab", count: 32)
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft))
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            appAuthorizationProvider: { DobbyAppAuthorization(appAPIKey: appKey, installationToken: owner) })

        let result = try await client.generate(photos: photos)
        XCTAssertEqual(result, draft)
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Dobby-App-Key"), appKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + owner)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["photos"], "Authorization must stay out of the photo payload")
        let sent = try XCTUnwrap(object["photos"] as? [[String: String]])
        XCTAssertEqual(sent.map { $0["id"] }, photos.map { Optional($0.id.uuidString) })
        XCTAssertEqual(sent.map { $0["role"] }, ["detail", "detail"])
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testMissingOrInvalidCommonAppKeyStopsBeforePhotoReadOrNetwork() async throws {
        let invalidKeys: [String?] = [nil, "", " ", "$(DOBBY_APP_API_KEY)", "YOUR_APP_API_KEY",
                                      "YOUR_DOBBY_APP_API_KEY", "invalid\nheader", "invalid\rheader", "invalid\tkey"]
        for key in invalidKeys {
            let stub = AutofillHTTPStub(status: 200, body: Data())
            defer { stub.remove() }
            let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
                appAuthorizationProvider: {
                    key.map { DobbyAppAuthorization(appAPIKey: $0, installationToken: String(repeating: "a", count: 64)) }
                })
            do {
                _ = try await client.generate(photos: [])
                XCTFail("A missing, unresolved, or invalid app key must not be transmitted")
            } catch {
                XCTAssertEqual(error as? ProductAutofillError, .notConfigured)
            }
            XCTAssertEqual(stub.requestCount, 0)
        }
    }

    func testInvalidCommonInstallationTokenStopsBeforePhotoReadOrNetwork() async throws {
        for owner in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                      String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                      String(repeating: "é", count: 64), "invalid\nheader"] {
            let stub = AutofillHTTPStub(status: 200, body: Data())
            defer { stub.remove() }
            let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
                appAuthorizationProvider: {
                    DobbyAppAuthorization(appAPIKey: "unit-test-common-app-key", installationToken: owner)
                })
            do {
                _ = try await client.generate(photos: [])
                XCTFail("An invalid installation identity must not be transmitted")
            } catch { XCTAssertEqual(error as? ProductAutofillError, .notConfigured) }
            XCTAssertEqual(stub.requestCount, 0)
        }
    }

    func testCommonAuthenticationServerFailureNeverExposesRawCredentials() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 1, directory: directory)
        let key = "unit-test-upstream-credential-marker"
        let owner = String(repeating: "cd", count: 32)
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["code": "unauthorized", "message": "Upstream echoed \(key) Bearer \(owner)"]
        ])
        let stub = AutofillHTTPStub(status: 401, body: body)
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            appAuthorizationProvider: { DobbyAppAuthorization(appAPIKey: key, installationToken: owner) })
        do {
            _ = try await client.generate(photos: photos)
            XCTFail("Unauthorized response must not become a generated draft")
        } catch {
            XCTAssertEqual(error as? ProductAutofillError, .unauthorized)
            XCTAssertFalse(error.localizedDescription.contains(key))
            XCTAssertFalse(error.localizedDescription.contains(owner))
            XCTAssertFalse(error.localizedDescription.contains("Upstream echoed"))
        }
        XCTAssertEqual(stub.requestCount, 1, "Authentication failures must not automatically retry")
    }

    #if DEBUG
    func testSyntheticAIResponsesStillRequireBothFixtureContextAndExplicitKnownMode() {
        XCTAssertNil(ProductAutofillClient.fixtureMode(environment: [:], isFixture: true))
        for mode in ["success", "delay", "failure", "failure-once"] {
            let environment = ["DOBBY_AI_FIXTURE_RESULT": mode]
            XCTAssertEqual(ProductAutofillClient.fixtureMode(environment: environment, isFixture: true), mode)
            XCTAssertNil(ProductAutofillClient.fixtureMode(environment: environment, isFixture: false))
        }
        for mode in ["", "unknown", "SUCCESS", " success", "success\n"] {
            XCTAssertNil(ProductAutofillClient.fixtureMode(
                environment: ["DOBBY_AI_FIXTURE_RESULT": mode], isFixture: true))
        }
    }
    #endif

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

    func testDebugDiagnosticMatchesUploadedBytesAndPreservesReturnedBrand() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let photos = try makePhotos(count: 2, directory: directory)
        let draft = ProductAutofillDraft(productName: "브랜드 응답 진단", brand: nil,
            description: "라벨 확인용 설명입니다.", reviewNotes: ["브랜드 미확인"])
        let stub = AutofillHTTPStub(status: 200, body: try JSONEncoder().encode(draft), headers: [
            "X-Dobby-AI-Search-Calls": "0", "X-Dobby-AI-Search-Attempts": "0", "X-Dobby-AI-Research-Status": "skipped"
        ])
        defer { stub.remove() }
        let client = ProductAutofillClient(endpoint: stub.endpoint, session: stub.session,
            diagnosticOrigin: "imageTest", bearerTokenProvider: { "diagnostic-test-secret-never-record" })
        let actual = try await client.generate(photos: photos)
        XCTAssertEqual(actual, draft)
        let entry = try XCTUnwrap(ProductAutofillDiagnostics.latest().first { $0.record.origin == "imageTest" })
        defer { try? FileManager.default.removeItem(at: entry.directory) }
        XCTAssertEqual(entry.record.draft, draft)
        XCTAssertEqual(entry.record.statusCode, 200)
        XCTAssertEqual(entry.record.outcome, "success")
        XCTAssertEqual(entry.record.search?.attempts, 0)
        XCTAssertEqual(entry.record.search?.completedCalls, 0)
        XCTAssertEqual(entry.record.search?.status, "skipped")
        let missingHeaders = try XCTUnwrap(HTTPURLResponse(url: stub.endpoint, statusCode: 200, httpVersion: nil, headerFields: [:]))
        XCTAssertNil(ProductAutofillDiagnostics.SearchActivity.read(missingHeaders))
        XCTAssertEqual(entry.record.photos.map(\.id), photos.map { $0.id.uuidString })
        let request = try XCTUnwrap(stub.request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let sent = try XCTUnwrap(object["photos"] as? [[String: String]])
        for (index, photo) in entry.record.photos.enumerated() {
            let encoded = try XCTUnwrap(sent[index]["imageDataUrl"]?.split(separator: ",").last)
            let expected = try XCTUnwrap(Data(base64Encoded: String(encoded)))
            XCTAssertEqual(try Data(contentsOf: entry.directory.appending(path: photo.filename)), expected)
            XCTAssertEqual(photo.bytes, expected.count)
            XCTAssertEqual(photo.sha256.count, 64)
        }
        let manifest = try String(contentsOf: entry.directory.appending(path: "manifest.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("diagnostic-test-secret-never-record"))
        XCTAssertFalse(manifest.contains("Authorization"))
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
    let endpoint: URL
    let status: Int
    let body: Data
    let headers: [String: String]
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var request: URLRequest? { lock.withLock { requests.last } }
    var requestCount: Int { lock.withLock { requests.count } }
    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutofillURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    init(status: Int, body: Data, headers: [String: String] = [:], endpoint: URL? = nil) {
        self.endpoint = endpoint ?? URL(string: "https://autofill-test.invalid/" + UUID().uuidString)!
        self.status = status
        self.body = body
        self.headers = headers
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
        // Never let a request from the test session escape to the network.
        true
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
            headerFields: ["Content-Type": "application/json"].merging(stub.headers) { _, value in value })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
