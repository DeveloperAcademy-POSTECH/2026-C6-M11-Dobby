//
//  ProductPhotoCarousel.swift
//  Dobby
//
//  Created by mason on 10/4/26.
//  Components folder owner: mason.
//

import SwiftUI

/// 입력 배열(촬영 순서)을 그대로 표시한다. 탐색은 선택·대표 사진을 변경하지 않는다.
struct ProductPhotoCarousel: View {
    let photos: [CapturedAsset]
    let representativePhotoID: UUID?
    @State private var focusedPhotoID: UUID?

    private var currentIndex: Int {
        photos.firstIndex { $0.id == focusedPhotoID } ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            if photos.isEmpty {
                ContentUnavailableView("촬영한 사진이 없어요", systemImage: "photo")
            } else {
                let width = geometry.size.width * 284 / 402
                VStack(spacing: 20) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(photos) { photo in
                                ProductPhotoCarouselCard(photo: photo,
                                    isRepresentative: photo.id == representativePhotoID)
                                    .frame(width: width, height: max(0, geometry.size.height - 26))
                                    .id(photo.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, (geometry.size.width - width) / 2,
                                    for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $focusedPhotoID, anchor: .center)
                    .accessibilityIdentifier("camera.photoCarousel")
                    pageIndicator
                }
            }
        }
        // Figma 402pt 화면: 카드 284×395pt + 점까지 20pt + 점 높이 6pt.
        .aspectRatio(402.0 / 421, contentMode: .fit)
        .onChange(of: photos.map(\.id), initial: true) { _, ids in
            if focusedPhotoID == nil || !ids.contains(where: { $0 == focusedPhotoID }) {
                focusedPhotoID = ids.first
            }
        }
    }

    private var pageIndicator: some View {
        let start = max(0, min(currentIndex - 3, photos.count - 7))
        return HStack(spacing: 4) {
            ForEach(start..<min(start + 7, photos.count), id: \.self) { index in
                Circle()
                    .fill(index == currentIndex ? Color.white : Color.gray)
                    .frame(width: index == currentIndex ? 6 : 4,
                           height: index == currentIndex ? 6 : 4)
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("촬영 사진 미리보기")
        .accessibilityValue("\(currentIndex + 1) / \(photos.count)")
        .accessibilityIdentifier("camera.photoCarouselPage")
        .accessibilityAdjustableAction { direction in
            let next = currentIndex + (direction == .increment ? 1 : -1)
            if photos.indices.contains(next) { focusedPhotoID = photos[next].id }
        }
    }
}

private struct ProductPhotoCarouselCard: View {
    let photo: CapturedAsset
    let isRepresentative: Bool
    @State private var imageAvailable: Bool?

    var body: some View {
        CameraPhotoView(source: photo.source, onLoad: { imageAvailable = $0 })
            .overlay {
                if imageAvailable == false {
                    Text("사진을 불러올 수 없어요").font(.caption)
                        .padding(8).background(.regularMaterial)
                }
            }
            .overlay(alignment: .topLeading) {
                if isRepresentative {
                    Text("썸네일").font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(red: 247 / 255, green: 96 / 255, blue: 21 / 255))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(photo.purpose == .measurement ? "실측 사진" : "상세 사진")
            .accessibilityValue(imageAvailable == false ? "사진 읽기 실패" : (isRepresentative ? "대표 사진" : ""))
    }
}
