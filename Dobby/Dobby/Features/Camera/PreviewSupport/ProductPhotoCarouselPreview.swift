//
//  ProductPhotoCarouselPreview.swift
//  Dobby
//
//  Created by mason on 10/4/26.
//

import SwiftUI

#Preview("촬영 순서 캐러셀") {
    ProductPhotoCarouselPreview()
}

private struct ProductPhotoCarouselPreview: View {
    @State private var photos: [CapturedAsset] = []
    @State private var failure: String?

    var body: some View {
        VStack {
            if let failure { Text(failure) }
            ProductPhotoCarousel(photos: photos, representativePhotoID: photos.first?.id)
        }
        .background(Color(red: 26 / 255, green: 25 / 255, blue: 25 / 255))
        .preferredColorScheme(.dark)
        .task {
            do {
                let model = try CameraPreviewPhotos.makeModel()
                for _ in 0..<3 { try await model.captureDetail() }
                photos = model.photos
            } catch { failure = "미리보기 사진을 불러오지 못했어요." }
        }
    }
}
