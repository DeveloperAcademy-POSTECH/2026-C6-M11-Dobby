import Foundation

/// Only a visual match can select showcase copy. All other requests keep the normal AI upload limit and order.
nonisolated struct ShowcaseProductAutofill: Sendable {
    let generator: any ProductAutofillGenerating
    var match: (@Sendable ([URL]) throws -> ShowcaseGarment?)?
    var sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void = { deadline in
        try await ContinuousClock().sleep(until: deadline)
    }

    @concurrent
    func generate(photos: [CapturedAsset], additionalPhotoURLs: [URL] = []) async throws -> ProductAutofillDraft {
        try Task.checkCancellation()
        try ProductAutofillPhotoEncoder.validateSelection(photos)
        let started = ContinuousClock.now
        if let match {
            let urls = photos.compactMap { photo -> URL? in
                guard case let .localFile(url, _) = photo.source else { return nil }
                return url
            }
            if urls.count == photos.count, let sample = try match(urls + additionalPhotoURLs) {
                // Include image recognition in the visible 10–15 seconds.
                try await sleepUntil(started + .milliseconds(Int.random(in: 10_000...15_000)))
                try Task.checkCancellation()
                return sample.productDraft
            }
        }
        try Task.checkCancellation()
        let uploadPhotos = Array(photos.prefix(ProductAutofillPhotoEncoder.maximumPhotoCount))
        return try await generator.generate(photos: uploadPhotos)
    }
}

private extension ShowcaseGarment {
    nonisolated var productDraft: ProductAutofillDraft {
        switch self {
        case .chakTee:
            ProductAutofillDraft(productName: "chak 반팔 티셔츠", brand: "chak", description: """
                - 베이지·토프 계열의 워싱감이 느껴지는 반팔 피그먼트 티셔츠입니다.
                - 여유 있는 실루엣에 가슴 한쪽의 작은 주황색 chak 브랜드 레터링 장식이 포인트입니다.
                """, reviewNotes: [])
        case .zaraShorts:
            ProductAutofillDraft(productName: "ZARA 연청 데님 쇼츠", brand: "ZARA", description: """
                - 연청 워싱의 하이웨이스트 데님 쇼츠로, 벨트 고리와 버튼 여밈, 앞주머니와 코인 포켓이 있습니다.
                - 뒷면에는 사선 요크와 큰 패치 포켓 두 개, 허리의 갈색 가죽 패치가 돋보입니다.
                - 여유 있는 핏과 깔끔한 밑단으로 캐주얼하게 입기 좋습니다.
                """, reviewNotes: [])
        }
    }
}
