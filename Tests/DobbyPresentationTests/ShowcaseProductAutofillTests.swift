import Foundation
import XCTest
@testable import Dobby

final class ShowcaseProductAutofillTests: XCTestCase {
    func testBothSamplesUseProvidedCopyWithoutAIAndChooseTenToFifteenSecondDeadlines() async throws {
        let expected: [(ShowcaseGarment, String, String, String)] = [
            (.chakTee, "chak 반팔 티셔츠", "chak", """
                - 베이지·토프 계열의 워싱감이 느껴지는 반팔 피그먼트 티셔츠입니다.
                - 여유 있는 실루엣에 가슴 한쪽의 작은 주황색 chak 브랜드 레터링 장식이 포인트입니다.
                """),
            (.zaraShorts, "ZARA 연청 데님 쇼츠", "ZARA", """
                - 연청 워싱의 하이웨이스트 데님 쇼츠로, 벨트 고리와 버튼 여밈, 앞주머니와 코인 포켓이 있습니다.
                - 뒷면에는 사선 요크와 큰 패치 포켓 두 개, 허리의 갈색 가죽 패치가 돋보입니다.
                - 여유 있는 핏과 깔끔한 밑단으로 캐주얼하게 입기 좋습니다.
                """)
        ]
        let photos = makePhotos(1)
        let generator = RecordingGenerator()
        for (garment, name, brand, detail) in expected {
            let earliest = ContinuousClock.now + .seconds(10)
            let autofill = ShowcaseProductAutofill(generator: generator, match: { _ in garment }, sleepUntil: { deadline in
                XCTAssertGreaterThanOrEqual(deadline, earliest)
                XCTAssertLessThanOrEqual(deadline, ContinuousClock.now + .seconds(15))
            })
            let draft = try await autofill.generate(photos: photos)
            XCTAssertEqual(draft, ProductAutofillDraft(productName: name, brand: brand, description: detail, reviewNotes: []))
        }
        let requests = await generator.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnknownPhotosUseNormalGeneratorWithOnlyFirstFivePhotosAndNoDelay() async throws {
        let generator = RecordingGenerator()
        let photos = makePhotos(7)
        let additional = [URL(fileURLWithPath: "/extra.jpg")]
        let autofill = ShowcaseProductAutofill(generator: generator, match: { urls in
            XCTAssertEqual(urls.count, 8)
            XCTAssertEqual(urls.last, additional.first)
            return nil
        }, sleepUntil: { _ in XCTFail("Only sample results should wait.") })
        let draft = try await autofill.generate(photos: photos, additionalPhotoURLs: additional)
        XCTAssertEqual(draft.productName, "AI")
        let requests = await generator.requests
        XCTAssertEqual(requests, [Array(photos.prefix(5))])
    }

    func testCancellingTheShowcaseDelayPropagatesWithoutFallingBackToAI() async throws {
        let waiting = expectation(description: "Reached showcase delay")
        let generator = RecordingGenerator()
        let autofill = ShowcaseProductAutofill(generator: generator, match: { _ in .chakTee }, sleepUntil: { deadline in
            waiting.fulfill()
            try await ContinuousClock().sleep(until: deadline)
        })
        let photos = makePhotos(1)
        let task = Task { try await autofill.generate(photos: photos) }
        await fulfillment(of: [waiting], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled generation returned a draft.")
        } catch is CancellationError {}
        let requests = await generator.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func makePhotos(_ count: Int) -> [CapturedAsset] {
        let sessionID = UUID()
        let garmentID = UUID()
        return (0..<count).map { index in
            CapturedAsset(id: UUID(), sessionID: sessionID, garmentID: garmentID, purpose: .detail,
                capturedAt: .now, source: .localFile(URL(fileURLWithPath: "/\(index).jpg"),
                    metadata: .init(pixelWidth: 100, pixelHeight: 100, contentType: "public.jpeg", orientation: .up)))
        }
    }
}

private actor RecordingGenerator: ProductAutofillGenerating {
    private(set) var requests = [[CapturedAsset]]()

    func generate(photos: [CapturedAsset]) async throws -> ProductAutofillDraft {
        requests.append(photos)
        return ProductAutofillDraft(productName: "AI", brand: nil, description: "AI", reviewNotes: [])
    }
}
