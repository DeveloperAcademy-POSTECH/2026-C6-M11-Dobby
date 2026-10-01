//
//  CameraPhotoView.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import SwiftUI
import ImageIO

/// 실제 파일을 표시하며 작은 썸네일은 축소 디코딩한다. 원본 파일은 변경하지 않는다.
struct CameraPhotoView: View {
    let source: CapturedAsset.Source
    var maximumPixelSize = 1600
    var contentMode: ContentMode = .fill
    var onLoad: ((Bool) -> Void)?
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Color(.secondarySystemBackground)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: source) {
            image = nil
            defer { onLoad?(image != nil) }
            guard case let .localFile(url, _) = source,
                  let file = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            image = CGImageSourceCreateThumbnailAtIndex(file, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary)
        }
    }
}
