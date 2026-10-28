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
    @State private var imageRequestID: UUID?

    private struct LoadIdentity: Equatable {
        let source: CapturedAsset.Source
        let maximumPixelSize: Int
    }

    private var loadIdentity: LoadIdentity {
        .init(source: source, maximumPixelSize: maximumPixelSize)
    }

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
        .task(id: loadIdentity) {
            let identity = loadIdentity
            let requestID = UUID()
            imageRequestID = requestID
            image = nil
            defer {
                if !Task.isCancelled, imageRequestID == requestID, loadIdentity == identity { onLoad?(image != nil) }
            }
            guard case let .localFile(url, _) = identity.source else { return }
            let request = ProductThumbnailRequest(url: url, maximumPixelSize: identity.maximumPixelSize)
            let decoded = await ProductThumbnailLoader.shared.image(for: request)
            guard !Task.isCancelled, imageRequestID == requestID, loadIdentity == identity else { return }
            image = decoded?.image
        }
    }
}
