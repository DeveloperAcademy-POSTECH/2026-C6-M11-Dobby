import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import Dobby

@MainActor
final class OuterwearLandmarkClientTests: XCTestCase {
    func testMissingCentersRetryWithoutGapEvidenceAndCompleteTotalSkipsRetry() async throws {
        for missing in [[], ["top_length_start"], ["hem_center"], ["top_length_start", "hem_center"]] {
            let requestID = UUID()
            var wire = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: responseData(requestID: requestID))
            if missing.contains("top_length_start") { wire.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain) }
            if missing.contains("hem_center") { wire.points["hem_center"] = .init(point: nil, visibility: .occluded) }
            let spy = GapRefinementSpy(initial: wire, fails: false)
            let mask = garmentMask(width: 200, height: 120)
            let output = try await OuterwearGarmentCropPipeline.recognize(image(width: 200, height: 120),
                orientation: .up, category: "Sweater", requestID: requestID, provider: spy, masks: { _ in [mask] })
            let diagnostics = try XCTUnwrap(output.recognition.diagnostics)
            XCTAssertEqual(output.poseRequests, missing.isEmpty ? 1 : 2)
            let calls = await spy.detailCalls
            XCTAssertEqual(calls, missing.isEmpty ? 0 : 1)
            XCTAssertEqual(Set(diagnostics.remoteCenterRefinement?.adoptedLandmarkIDs ?? []), Set(missing))
            XCTAssertTrue(output.recognition.points.filter { ["top_length_start", "hem_center"].contains($0.id) }.allSatisfy(\.isVisible))
            let crop = try XCTUnwrap(diagnostics.remoteGarmentCrop)
            let original = try OuterwearComparisonGeometry.restoring(wire, crops: [.init(region: .garment, rect: crop.rect)])
            for (id, observed) in OuterwearComparisonGeometry.observations(original) where !missing.contains(id) {
                XCTAssertEqual(output.recognition.points.first { $0.id == id }?.point, observed.point,
                    "Successful first-pass points, including the other total endpoint, must not move")
            }
        }
    }

    func testLengthRefinementUploadsOnlyUpperAndHemAndChecksItsNarrowResponse() async throws {
        let requestID = UUID()
        let response = OuterwearLengthRefinementResponse(requestID: requestID.uuidString, view: .front, neckStyle: .hood,
            frontNeckSeamCenter: .init(point: .init(x: 0.4, y: 0.3), visibility: .visible),
            hemCenter: .init(point: nil, visibility: .uncertain), centerSupport: .init())
        let stub = OuterwearHTTPStub(body: try JSONEncoder().encode(response))
        defer { stub.remove() }
        let crops: [OuterwearComparisonCrop] = [
            .init(region: .upper, rect: .init(x: 0.2, y: 0, width: 0.6, height: 0.5)),
            .init(region: .hem, rect: .init(x: 0.2, y: 0.6, width: 0.6, height: 0.4))]
        let result = try await makeClient(stub).refineCenters(image: image(width: 200, height: 100), context: .init(x: 0, y: 0, width: 1, height: 1),
            crops: crops, category: "Hoodie", requestID: requestID)
        XCTAssertEqual(result.frontNeckSeamCenter.point, response.frontNeckSeamCenter.point)
        XCTAssertNil(result.hemCenter.point)
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.url, stub.endpoint)
        XCTAssertEqual(request.timeoutInterval, 12)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let regions = try XCTUnwrap(body["regions"] as? [[String: Any]])
        XCTAssertEqual(regions.compactMap { $0["id"] as? String }, ["upper", "hem"])
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testLengthRefinementDeadlineCancelsOnlyItsSingleRequest() async throws {
        let stub = OuterwearHTTPStub(body: nil)
        defer { stub.remove() }
        let crops = [OuterwearComparisonRegion.upper, .hem].map {
            OuterwearComparisonCrop(region: $0, rect: .init(x: 0, y: 0, width: 1, height: 1))
        }
        do {
            _ = try await makeClient(stub, timeout: 0.1).refineCenters(image: image(),
                context: .init(x: 0, y: 0, width: 1, height: 1), crops: crops, category: "Hoodie", requestID: UUID())
            XCTFail("Stalled detail must time out")
        } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .timeout) }
        try await waitForRequestStop(stub)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testSmallGapRetriesOnlyMissingCenterAndKeepsOtherFirstPassPoints() async throws {
        for fails in [false, true] {
            let requestID = UUID()
            var wire = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: responseData(requestID: requestID))
            wire.frontNeckSeamCenter = .init(point: nil, visibility: .uncertain)
            let hem = OuterwearCenterSupport(left: .init(x: 0.485, y: 0.94), right: .init(x: 0.515, y: 0.94))
            wire.centerSupport?.hemCenter = hem
            wire.points["hem_center"] = .init(point: hem.midpoint, visibility: .estimated)
            let spy = GapRefinementSpy(initial: wire, fails: fails)
            let mask = garmentMask(width: 200, height: 120)
            let output = try await OuterwearGarmentCropPipeline.recognize(image(width: 200, height: 120),
                orientation: .up, category: "Hoodie", requestID: requestID, provider: spy, masks: { _ in [mask] })
            let diagnostics = try XCTUnwrap(output.recognition.diagnostics)
            let crop = try XCTUnwrap(diagnostics.remoteGarmentCrop)
            XCTAssertEqual(output.poseRequests, 2)
            XCTAssertEqual(diagnostics.remoteCenterRefinement?.crops.map(\.region), [.upper, .hem])
            let count = await spy.detailCalls
            XCTAssertEqual(count, 1)
            XCTAssertTrue(output.recognition.points.first { $0.id == "hem_center" }!.isVisible)
            XCTAssertEqual(output.recognition.points.first { $0.id == "top_length_start" }!.isVisible, !fails)
            let shoulder = try XCTUnwrap(output.recognition.points.first { $0.id == "shoulder_left" })
            XCTAssertEqual(shoulder.point.x, crop.rect.x + 0.3 * crop.rect.width, accuracy: 1e-12)
            XCTAssertNil(crop.localResponse.frontNeckSeamCenter?.point)
            XCTAssertEqual(diagnostics.remoteCenterRefinement?.adoptedLandmarkIDs, fails ? [] : ["top_length_start"])
            if !fails {
                XCTAssertEqual(output.recognition.points.first { $0.id == "top_length_start" }!.point.y, 0.3, accuracy: 1e-12)
                XCTAssertEqual(diagnostics.centerEstimates?.count, 2)
                let restored = try JSONDecoder().decode(GarmentRecognitionDiagnostics.self, from: JSONEncoder().encode(diagnostics))
                XCTAssertEqual(restored.remoteCenterRefinement?.adoptedLandmarkIDs, ["top_length_start"])
            }
        }
    }

    func testProductionCropUploadsGarmentAndRestoresOriginalDepthCoordinatesInAllRotations() async throws {
        let original = try image(width: 200, height: 120)
        for orientation in [ImageOrientation.up, .right, .down, .left] {
            let requestID = UUID()
            let stub = OuterwearHTTPStub(body: try responseData(requestID: requestID))
            defer { stub.remove() }
            let quarterTurn = orientation == .right || orientation == .left
            let mask = garmentMask(width: quarterTurn ? 120 : 200, height: quarterTurn ? 200 : 120)
            let spy = CropMaskSpy(masks: [mask])
            let result = try await OuterwearGarmentCropPipeline.recognize(original, orientation: orientation,
                category: "Sweater", requestID: requestID, provider: makeClient(stub), masks: { spy.analyze($0) })
            XCTAssertEqual(spy.sizes, [mask.size], "One upright segmentation supplies crop and validation")
            XCTAssertEqual(stub.requestCount, 1)
            XCTAssertEqual(result.foregroundRequests, 1)
            XCTAssertEqual(result.poseRequests, 1)
            let diagnostics = try XCTUnwrap(result.recognition.diagnostics)
            let crop = try XCTUnwrap(diagnostics.remoteGarmentCrop)
            XCTAssertEqual(crop.sourceSize, .init(width: 200, height: 120))
            XCTAssertEqual(crop.uprightSize, mask.size)
            // Independent pixel bounds for a 6%-padded [20%,15%,60%,70%] garment.
            let left = floor(Double(mask.size.width) * 0.164)
            let top = floor(Double(mask.size.height) * 0.108)
            let right = ceil(Double(mask.size.width) * 0.836)
            let bottom = ceil(Double(mask.size.height) * 0.892)
            XCTAssertEqual(crop.rect.x, left / Double(mask.size.width), accuracy: 1e-12)
            XCTAssertEqual(crop.rect.y, top / Double(mask.size.height), accuracy: 1e-12)
            XCTAssertEqual(crop.rasterSize, .init(width: Int(right - left), height: Int(bottom - top)))
            let request = try XCTUnwrap(stub.request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(payload["category"] as? String, "Sweater")
            let upload = try XCTUnwrap(payload["image"] as? [String: Any])
            XCTAssertEqual(upload["width"] as? Int, crop.rasterSize.width)
            XCTAssertEqual(upload["height"] as? Int, crop.rasterSize.height)
            let url = try XCTUnwrap(upload["imageDataUrl"] as? String)
            let jpeg = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
            let sent = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            func rawPoint(_ local: ImagePoint) -> ImagePoint {
                let u = crop.rect.x + local.x * crop.rect.width
                let v = crop.rect.y + local.y * crop.rect.height
                switch orientation {
                case .up: return .init(x: u, y: v)
                case .right: return .init(x: v, y: 1 - u)
                case .down: return .init(x: 1 - u, y: 1 - v)
                case .left: return .init(x: 1 - v, y: u)
                }
            }
            for p in [ImagePoint(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.2), .init(x: 0.2, y: 0.8), .init(x: 0.8, y: 0.8)] {
                let actual = try pixel(sent, at: p), expected = try pixel(original, at: rawPoint(p))
                for c in 0..<3 { XCTAssertEqual(Double(actual[c]), Double(expected[c]), accuracy: 15) }
            }
            let observations = OuterwearComparisonGeometry.observations(crop.localResponse)
            for point in result.recognition.points {
                let local = try XCTUnwrap(observations[point.id]?.point)
                let expected = rawPoint(local)
                XCTAssertEqual(point.point.x, expected.x, accuracy: 1e-12)
                XCTAssertEqual(point.point.y, expected.y, accuracy: 1e-12)
                XCTAssertTrue(point.isVisible, point.id)
                let mask = result.selection.mask
                XCTAssertEqual(mask.values[Int(expected.y * Double(mask.size.height)) * mask.size.width
                    + Int(expected.x * Double(mask.size.width))], 1)
            }
            XCTAssertEqual(result.selection.mask.size, crop.sourceSize)
            XCTAssertEqual(diagnostics.totalLengthConvention, GarmentLandmarkModelContract.frontGapConvention)
            let archived = try JSONEncoder().encode(diagnostics)
            let reopened = try JSONDecoder().decode(GarmentRecognitionDiagnostics.self, from: archived)
            XCTAssertEqual(reopened.remoteGarmentCrop?.rect, crop.rect)
            XCTAssertEqual(reopened.remoteGarmentCrop?.localResponse.frontNeckSeamCenter?.point,
                           crop.localResponse.frontNeckSeamCenter?.point)
            var legacy = diagnostics
            legacy.remoteGarmentCrop = nil
            XCTAssertNil(try JSONDecoder().decode(GarmentRecognitionDiagnostics.self,
                from: JSONEncoder().encode(legacy)).remoteGarmentCrop)
        }
    }

    func testProductionCropPreservesNullAndRejectsBackgroundWithoutMovingPoints() async throws {
        let requestID = UUID()
        var wire = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: responseData(requestID: requestID))
        wire.frontNeckSeamCenter = .init(point: nil, visibility: .occluded)
        wire.points["sleeve_end_left"] = .init(point: .init(x: 0.01, y: 0.6), visibility: .visible)
        let stub = OuterwearHTTPStub(body: try JSONEncoder().encode(wire))
        defer { stub.remove() }
        let mask = garmentMask(width: 200, height: 120)
        let result = try await OuterwearGarmentCropPipeline.recognize(image(width: 200, height: 120),
            orientation: .up, category: "Hoodie", requestID: requestID, provider: makeClient(stub), masks: { _ in [mask] })
        let diagnostics = try XCTUnwrap(result.recognition.diagnostics)
        let crop = try XCTUnwrap(diagnostics.remoteGarmentCrop)
        XCTAssertNil(crop.localResponse.frontNeckSeamCenter?.point)
        XCTAssertEqual(crop.localResponse.frontNeckSeamCenter?.visibility, .occluded)
        XCTAssertFalse(try XCTUnwrap(result.recognition.points.first { $0.id == "top_length_start" }).isVisible)
        let cuff = try XCTUnwrap(result.recognition.points.first { $0.id == "sleeve_end_left" })
        XCTAssertFalse(cuff.isVisible)
        XCTAssertEqual(cuff.point.x, crop.rect.x + 0.01 * crop.rect.width, accuracy: 1e-12)
        XCTAssertEqual(diagnostics.pointAssessments.first { $0.landmarkID == cuff.id }?.status, .outsideMask)
        XCTAssertTrue(try XCTUnwrap(result.recognition.points.first { $0.id == "armpit_left" }).isVisible)
        XCTAssertEqual(stub.requestCount, 2)
        XCTAssertEqual(diagnostics.remoteCenterRefinement?.failure, "detail_unavailable")
    }

    func testProductionCropRejectsMissingMultipleOrInvalidMasksBeforeUpload() async throws {
        let stub = OuterwearHTTPStub(body: nil)
        defer { stub.remove() }
        let mask = garmentMask(width: 200, height: 120)
        let invalid = GarmentMask(size: mask.size, values: [1])
        let cases: [([GarmentMask], GarmentMaskAssociationError)] = [
            ([], .noForeground), ([mask, mask], .multipleForegrounds), ([invalid], .invalidMask)]
        for (masks, expected) in cases {
            do {
                _ = try await OuterwearGarmentCropPipeline.recognize(image(width: 200, height: 120),
                    orientation: .up, category: "Jacket", provider: makeClient(stub), masks: { _ in masks })
                XCTFail("Invalid crop must not start a request")
            } catch { XCTAssertEqual(error as? GarmentMaskAssociationError, expected) }
        }
        XCTAssertEqual(stub.requestCount, 0)
    }

    private func garmentMask(width: Int, height: Int) -> GarmentMask {
        var values = [UInt8](repeating: 0, count: width * height)
        for y in (height * 15 / 100)..<(height * 85 / 100) {
            for x in (width / 5)..<(width * 4 / 5) { values[y * width + x] = 1 }
        }
        return .init(size: .init(width: width, height: height), values: values)
    }

    func testComparisonCropRasterMatchesRecordedInverseTransform() throws {
        let original = try image(width: 200, height: 120)
        let crop = OuterwearComparisonCrop(region: .garment,
            rect: try OuterwearComparisonGeometry.aligned(.init(x: 0.1, y: 0.1, width: 0.8, height: 0.7),
                                                          size: .init(width: 200, height: 120)))
        let input = try OuterwearLandmarkComparisonRunner.input(original, crop: crop)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(input.record.jpeg as CFData, nil))
        let raster = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(raster.width, 160)
        XCTAssertEqual(raster.height, 84)
        XCTAssertEqual(input.record.crop.rect, crop.rect)
        for p in [ImagePoint(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.2), .init(x: 0.2, y: 0.8), .init(x: 0.8, y: 0.8)] {
            let raw = ImagePoint(x: crop.rect.x + p.x * crop.rect.width, y: crop.rect.y + p.y * crop.rect.height)
            let actual = try pixel(raster, at: p), expected = try pixel(original, at: raw)
            for c in 0..<3 { XCTAssertEqual(Double(actual[c]), Double(expected[c]), accuracy: 15) }
        }
    }

    func testRefinementUsesSeparateRouteAndPreservesLocalCoordinates() async throws {
        let requestID = UUID()
        let encoded = try OuterwearLandmarkImageEncoder.encode(image(), orientation: .up)
        let regions = OuterwearComparisonRegion.allCases.filter { $0 != .garment }.map {
            OuterwearLandmarkImageEncoder.Region(id: $0.rawValue, image: encoded)
        }
        let data = try JSONSerialization.data(withJSONObject: ["refinementVersion": "outerwear-front-gap-refinement-v4",
            "localResponse": responseObject(requestID: requestID)])
        let stub = OuterwearHTTPStub(body: data)
        defer { stub.remove() }
        let client = OuterwearLandmarkClient(endpoint: URL(string: "https://unused.invalid/v4/garments/landmarks")!,
            session: stub.session, refinementEndpoint: stub.endpoint, bearerTokenProvider: { "test-token" })
        let response = try await client.recognizeEncoded(image: encoded, regions: regions, category: "Hoodie", requestID: requestID)
        XCTAssertEqual(response.points["hem_center"]?.point, ImagePoint(x: 0.5, y: 0.9))
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.url, stub.endpoint)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["requestId", "category", "image", "regions"])
        XCTAssertEqual((payload["regions"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testRefinementCannotAcceptBareWholeImageResponseOrUnknownEnvelope() async throws {
        let requestID = UUID()
        let encoded = try OuterwearLandmarkImageEncoder.encode(image(), orientation: .up)
        let regions = OuterwearComparisonRegion.allCases.filter { $0 != .garment }.map {
            OuterwearLandmarkImageEncoder.Region(id: $0.rawValue, image: encoded)
        }
        for body in [try responseData(requestID: requestID),
                     try JSONSerialization.data(withJSONObject: ["refinementVersion": "unknown", "localResponse": responseObject(requestID: requestID)])] {
            let stub = OuterwearHTTPStub(body: body)
            defer { stub.remove() }
            let client = OuterwearLandmarkClient(session: stub.session, refinementEndpoint: stub.endpoint, bearerTokenProvider: { "test-token" })
            do {
                _ = try await client.recognizeEncoded(image: encoded, regions: regions, category: "Hoodie", requestID: requestID)
                XCTFail("Coordinate provenance is mandatory")
            } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .invalidResponse) }
        }
    }

    func testCommonAuthorizationAndCapturedRequestIdentityStayOutOfImageMetadata() async throws {
        let requestID = UUID()
        let stub = OuterwearHTTPStub(body: try responseData(requestID: requestID))
        defer { stub.remove() }
        let owner = String(repeating: "ab", count: 32)
        let client = OuterwearLandmarkClient(endpoint: stub.endpoint, session: stub.session,
            appAuthorizationProvider: { .init(appAPIKey: "test-common-app-key", installationToken: owner) })
        let response = try await client.recognize(image: image(), orientation: .right,
                                                category: "Jacket", requestID: requestID)
        XCTAssertEqual(response.requestID, requestID.uuidString)
        XCTAssertEqual(response.schemaVersion, OuterwearLandmarkResponse.expectedGapSchemaVersion)
        XCTAssertEqual(response.modelVersion, OuterwearLandmarkResponse.expectedGapModelVersion)
        XCTAssertEqual(OuterwearLandmarkClient.endpoint.path, "/v4/garments/landmarks")
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 25)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + owner)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Dobby-App-Key"), "test-common-app-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["requestId", "image", "category"])
        XCTAssertEqual(payload["requestId"] as? String, requestID.uuidString)
        XCTAssertEqual(payload["category"] as? String, "Jacket")
        let upload = try XCTUnwrap(payload["image"] as? [String: Any])
        XCTAssertEqual(Set(upload.keys), ["imageDataUrl", "width", "height"])
        XCTAssertEqual(upload["width"] as? Int, 48)
        XCTAssertEqual(upload["height"] as? Int, 80)
        XCTAssertTrue((upload["imageDataUrl"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(stub.requestCount, 1)
        // The remote response is still upright here. Only the core policy maps
        // it back into the original captured frame.
        XCTAssertEqual(response.points["hem_center"]?.point?.x, 0.5)
        XCTAssertEqual(response.points["hem_center"]?.point?.y, 0.9)
    }

    func testMissingAndInvalidAuthorizationNeverSendsAnImage() async throws {
        let authorizations: [DobbyAppAuthorization?] = [nil,
            .init(appAPIKey: "$(UNRESOLVED)", installationToken: String(repeating: "a", count: 64)),
            .init(appAPIKey: "test-key", installationToken: "invalid-owner"),
            .init(appAPIKey: "invalid\nkey", installationToken: String(repeating: "a", count: 64))]
        for authorization in authorizations {
            let stub = OuterwearHTTPStub(body: Data())
            defer { stub.remove() }
            let client = OuterwearLandmarkClient(endpoint: stub.endpoint, session: stub.session,
                                                appAuthorizationProvider: { authorization })
            do {
                _ = try await client.recognize(image: image(), orientation: .up, category: "Coat", requestID: UUID())
                XCTFail("Invalid authorization must stop before transmission")
            } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .notConfigured) }
            XCTAssertEqual(stub.requestCount, 0)
        }
    }

    func testMalformedOversizedAndDifferentFrameResponsesAreRejected() async throws {
        let requestID = UUID()
        var wrongSchema = try responseObject(requestID: requestID)
        wrongSchema["modelVersion"] = "unknown-model"
        var missingPoint = try responseObject(requestID: requestID)
        var points = try XCTUnwrap(missingPoint["points"] as? [String: Any])
        points.removeValue(forKey: "hem_center")
        missingPoint["points"] = points
        var missingFrontObservation = try responseObject(requestID: requestID)
        missingFrontObservation.removeValue(forKey: "frontNeckSeamCenter")
        for data in [Data("{}".utf8), Data(repeating: 65, count: 64 * 1024 + 1),
                     try responseData(requestID: UUID()),
                     try JSONSerialization.data(withJSONObject: wrongSchema),
                     try JSONSerialization.data(withJSONObject: missingPoint),
                     try JSONSerialization.data(withJSONObject: missingFrontObservation)] {
            let stub = OuterwearHTTPStub(body: data)
            defer { stub.remove() }
            let client = makeClient(stub)
            do {
                _ = try await client.recognize(image: image(), orientation: .up, category: "Coat", requestID: requestID)
                XCTFail("An invalid or stale-frame response must not produce landmarks")
            } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .invalidResponse) }
            XCTAssertEqual(stub.requestCount, 1)
        }
    }

    func testArchiveCompatibleV1ResponseCannotSatisfyANewV3Request() async throws {
        let requestID = UUID()
        var object = try responseObject(requestID: requestID)
        object["schemaVersion"] = OuterwearLandmarkResponse.expectedSchemaVersion
        object["modelVersion"] = OuterwearLandmarkResponse.expectedModelVersion
        object.removeValue(forKey: "frontNeckSeamCenter")
        object.removeValue(forKey: "centerSupport")
        object["backNeckSeamCenter"] = ["point": NSNull(), "visibility": "uncertain"]
        let data = try JSONSerialization.data(withJSONObject: object)
        // Old saved observations remain valid; accepting one from the live v4
        // endpoint would silently drop the new front-length contract.
        let legacy = try JSONDecoder().decode(OuterwearLandmarkResponse.self, from: data)
        try legacy.validate(expectedRequestID: requestID.uuidString)
        let stub = OuterwearHTTPStub(body: data)
        defer { stub.remove() }
        do {
            _ = try await makeClient(stub).recognize(image: image(), orientation: .up,
                                                    category: "Jacket", requestID: requestID)
            XCTFail("A v1 success response must not replace the v4 request contract")
        } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .invalidResponse) }
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testFrontLengthObservationIsReturnedWithoutInventingABackSeam() async throws {
        let requestID = UUID()
        var object = try responseObject(requestID: requestID)
        object["view"] = "front"
        object["frontNeckSeamCenter"] = ["point": ["x": 0.5, "y": 0.24], "visibility": "visible"]
        let stub = OuterwearHTTPStub(body: try JSONSerialization.data(withJSONObject: object))
        defer { stub.remove() }
        let response = try await makeClient(stub).recognize(image: image(), orientation: .left,
                                                          category: "Jacket", requestID: requestID)
        XCTAssertEqual(response.frontNeckSeamCenter?.point, ImagePoint(x: 0.5, y: 0.24))
        XCTAssertEqual(response.frontNeckSeamCenter?.visibility, .visible)
        XCTAssertNil(response.backNeckSeamCenter.point)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testUnavailableSeamStaysNullForCoreReview() async throws {
        let requestID = UUID()
        var object = try responseObject(requestID: requestID)
        object["frontNeckSeamCenter"] = ["point": NSNull(), "visibility": "occluded"]
        let stub = OuterwearHTTPStub(body: try JSONSerialization.data(withJSONObject: object))
        defer { stub.remove() }
        let response = try await makeClient(stub).recognize(image: image(), orientation: .up,
                                                          category: "Coat", requestID: requestID)
        XCTAssertNil(response.totalLengthStart.point)
        XCTAssertEqual(response.totalLengthStart.visibility, .occluded)
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testServerErrorsAreSafeAndNeverAutomaticallyRetried() async throws {
        for (status, code, expected) in [
            (401, "unauthorized", OuterwearLandmarkClientError.unauthorized),
            (503, "ai_configuration_error", .serverNotConfigured),
            (504, "ai_timeout", .timeout),
            (429, "ai_rate_limited", .busy),
            (422, "photo_unusable", .photoUnusable),
            (502, "invalid_ai_response", .invalidResponse)
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["error": ["code": code,
                "message": "untrusted diagnostic secret-credential-marker"]])
            let stub = OuterwearHTTPStub(status: status, body: data)
            defer { stub.remove() }
            do {
                _ = try await makeClient(stub).recognize(image: image(), orientation: .up,
                                                        category: "Coat", requestID: UUID())
                XCTFail("An HTTP failure must not produce points")
            } catch {
                XCTAssertEqual(error as? OuterwearLandmarkClientError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-credential-marker"))
                XCTAssertFalse(error.localizedDescription.contains("untrusted diagnostic"))
            }
            XCTAssertEqual(stub.requestCount, 1)
        }
    }

    func testCancellationStopsTheInFlightURLSessionRequest() async throws {
        let stub = OuterwearHTTPStub(body: nil)
        defer { stub.remove() }
        let client = makeClient(stub)
        let raster = try image()
        let task = Task {
            try await client.recognize(image: raster, orientation: .up, category: "Jacket", requestID: UUID())
        }
        try await waitForRequest(stub)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled frame must not return points") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForRequestStop(stub)
        XCTAssertEqual(stub.requestCount, 1)
        XCTAssertEqual(stub.stopCount, 1)
    }

    func testDeadlineCancelsAStalledRequestWithoutRetry() async throws {
        let stub = OuterwearHTTPStub(body: nil)
        defer { stub.remove() }
        let client = makeClient(stub, timeout: 0.1)
        do {
            _ = try await client.recognize(image: image(), orientation: .up, category: "Coat", requestID: UUID())
            XCTFail("A stalled request must hit its independent deadline")
        } catch { XCTAssertEqual(error as? OuterwearLandmarkClientError, .timeout) }
        try await waitForRequestStop(stub)
        XCTAssertEqual(stub.requestCount, 1)
        XCTAssertEqual(stub.stopCount, 1)
    }

    func testAllUploadRotationsMatchTheSharedCoordinateTransformWithoutCropping() throws {
        let original = try image()
        for orientation in ImageOrientation.allCases {
            let upload = try OuterwearLandmarkImageEncoder.encode(original, orientation: orientation)
            let data = try jpegData(upload)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let raster = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let quarterTurn = orientation == .left || orientation == .right
            XCTAssertEqual(raster.width, quarterTurn ? original.height : original.width)
            XCTAssertEqual(raster.height, quarterTurn ? original.width : original.height)
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            for quadrant in 0..<4 {
                let display = ImagePoint(x: quadrant % 2 == 0 ? 0.25 : 0.75,
                                         y: quadrant < 2 ? 0.25 : 0.75)
                let originalPoint = ImageCoordinateTransform.displayToOriginal(display, orientation: orientation)
                let expected = try pixel(original, at: originalPoint)
                let actual = try pixel(raster, at: display)
                for channel in 0..<3 {
                    XCTAssertEqual(Double(actual[channel]), Double(expected[channel]), accuracy: 35,
                                   "\(orientation) quadrant \(quadrant)")
                }
            }
        }
        XCTAssertEqual(original.width, 80)
        XCTAssertEqual(original.height, 48)
    }

    func testUploadResizeKeepsTheWholeImageAspectAndBudget() throws {
        let original = try image(width: 4096, height: 3072)
        let upload = try OuterwearLandmarkImageEncoder.encode(original, orientation: .left)
        XCTAssertEqual(upload.width, 1536)
        XCTAssertEqual(upload.height, 2048)
        XCTAssertEqual(Double(upload.width) / Double(upload.height), 3072.0 / 4096.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(try jpegData(upload).count, OuterwearLandmarkImageEncoder.maximumImageBytes)
    }

    private func makeClient(_ stub: OuterwearHTTPStub, timeout: TimeInterval = 25) -> OuterwearLandmarkClient {
        .init(endpoint: stub.endpoint, session: stub.session, timeout: timeout,
              lengthRefinementEndpoint: stub.endpoint,
              bearerTokenProvider: { "test-development-auth" })
    }

    private func waitForRequest(_ stub: OuterwearHTTPStub) async throws {
        for _ in 0..<100 {
            if stub.requestCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Request did not start")
    }

    private func waitForRequestStop(_ stub: OuterwearHTTPStub) async throws {
        // URLSession reports task cancellation before its URLProtocol callback
        // necessarily reaches the protocol queue on the iOS simulator.
        for _ in 0..<100 {
            if stub.stopCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The cancelled URLSession request did not stop")
    }

    private func responseData(requestID: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: responseObject(requestID: requestID))
    }

    private func responseObject(requestID: UUID) throws -> [String: Any] {
        let coordinates: [(String, Double, Double)] = [
            ("neck_left", 0.4, 0.15), ("neck_right", 0.6, 0.15),
            ("shoulder_left", 0.3, 0.2), ("shoulder_right", 0.7, 0.2),
            ("armpit_left", 0.3, 0.4), ("armpit_right", 0.7, 0.4),
            ("sleeve_end_left", 0.1, 0.6), ("sleeve_end_right", 0.9, 0.6),
            ("hem_left", 0.3, 0.9), ("hem_center", 0.5, 0.9), ("hem_right", 0.7, 0.9)]
        let points = Dictionary(uniqueKeysWithValues: coordinates.map { id, x, y in
            (id, ["point": ["x": x, "y": y], "visibility": "visible"] as [String: Any])
        })
        return ["requestId": requestID.uuidString,
                "schemaVersion": OuterwearLandmarkResponse.expectedGapSchemaVersion,
                "modelVersion": OuterwearLandmarkResponse.expectedGapModelVersion, "model": "gpt-6-luna",
                "view": "front", "neckStyle": "hood", "points": points,
                "centerSupport": ["frontNeckSeamCenter": NSNull(), "hem_center": NSNull()],
                "frontNeckSeamCenter": ["point": ["x": 0.5, "y": 0.24], "visibility": "visible"]]
    }

    private func image(width: Int = 80, height: Int = 48) throws -> CGImage {
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
        return try XCTUnwrap(context.makeImage())
    }

    private func jpegData(_ upload: OuterwearLandmarkImageEncoder.Image) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: String(upload.imageDataUrl.dropFirst("data:image/jpeg;base64,".count))))
    }

    private func pixel(_ image: CGImage, at point: ImagePoint) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: Int(point.x * Double(image.width)),
            y: Int(point.y * Double(image.height)), width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

private actor GapRefinementSpy: OuterwearLandmarkProviding, OuterwearCenterRefining {
    let initial: OuterwearLandmarkResponse
    let fails: Bool
    private(set) var detailCalls = 0
    init(initial: OuterwearLandmarkResponse, fails: Bool) { self.initial = initial; self.fails = fails }
    func recognize(image: CGImage, orientation: ImageOrientation, category: String,
                   requestID: UUID) async throws -> OuterwearLandmarkResponse { initial }
    func refineCenters(image: CGImage, context: NormalizedRect, crops: [OuterwearComparisonCrop],
                       category: String, requestID: UUID) async throws -> OuterwearLengthRefinementResponse {
        detailCalls += 1
        if fails { throw OuterwearLandmarkClientError.serverUnavailable }
        let rect = crops.first { $0.region == .upper }!.rect
        func local(_ p: ImagePoint) -> ImagePoint { .init(x: (p.x - rect.x) / rect.width, y: (p.y - rect.y) / rect.height) }
        let neck = OuterwearCenterSupport(left: local(.init(x: 0.48, y: 0.3)), right: local(.init(x: 0.52, y: 0.3)))
        let hem = crops.first { $0.region == .hem }!.rect
        return .init(requestID: requestID.uuidString, view: .front, neckStyle: .hood,
            frontNeckSeamCenter: .init(point: neck.midpoint, visibility: .estimated),
            hemCenter: .init(point: .init(x: (0.5 - hem.x) / hem.width, y: (0.84 - hem.y) / hem.height), visibility: .visible),
            centerSupport: .init(frontNeckSeamCenter: neck))
    }
}

private nonisolated final class CropMaskSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSizes: [PixelSize] = []
    private let masks: [GarmentMask]
    init(masks: [GarmentMask]) { self.masks = masks }
    var sizes: [PixelSize] { lock.withLock { capturedSizes } }
    func analyze(_ image: CGImage) -> [GarmentMask] {
        lock.withLock { capturedSizes.append(.init(width: image.width, height: image.height)) }
        return masks
    }
}

private nonisolated final class OuterwearHTTPStub: @unchecked Sendable {
    let endpoint = URL(string: "https://outerwear-test.invalid/" + UUID().uuidString)!
    let status: Int
    /// Nil deliberately leaves the request pending until cancelled.
    let body: Data?
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var stops = 0
    var request: URLRequest? { lock.withLock { requests.last } }
    var requestCount: Int { lock.withLock { requests.count } }
    var stopCount: Int { lock.withLock { stops } }
    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OuterwearURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    init(status: Int = 200, body: Data?) {
        self.status = status
        self.body = body
        OuterwearURLProtocol.register(self)
    }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func recordStop() { lock.withLock { stops += 1 } }
    func remove() { OuterwearURLProtocol.remove(endpoint) }
}

private nonisolated final class OuterwearURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [URL: OuterwearHTTPStub] = [:]
    static func register(_ stub: OuterwearHTTPStub) { lock.withLock { stubs[stub.endpoint] = stub } }
    static func remove(_ url: URL) { lock.withLock { _ = stubs.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "outerwear-test.invalid" }
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
        guard let body = stub.body else { return }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        guard let url = request.url, let stub = Self.lock.withLock({ Self.stubs[url] }) else { return }
        stub.recordStop()
    }
}
