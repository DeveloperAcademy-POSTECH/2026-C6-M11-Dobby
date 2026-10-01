//
//  CapturedAsset.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// 사진 원본과 촬영 식별자를 전달한다. 실측 입력은 영구 저장소, 상세 사진은 카메라 임시 저장소에 있다.
/// 데모의 mock placeholder에는 파일 URL이나 이미지 정보를 만들지 않는다.
struct CapturedAsset: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let garmentID: UUID
    let purpose: Purpose
    let capturedAt: Date
    let source: Source

    enum Purpose: String, Sendable {
        case measurement
        case detail
    }

    enum Source: Equatable, Sendable {
        case mockPlaceholder
        /// The camera-side store owns this original file; consumers must not delete it.
        case localFile(URL, metadata: ImageMetadata)
    }

    struct ImageMetadata: Equatable, Sendable {
        /// Encoded pixel dimensions before applying EXIF orientation.
        let pixelWidth: Int
        let pixelHeight: Int
        /// Uniform type identifier, e.g. public.jpeg. No format is agreed yet.
        let contentType: String
        let orientation: Orientation
    }

    /// EXIF orientation, including mirrored images. Preview coordinates are not image coordinates.
    enum Orientation: Int, Sendable {
        case up = 1
        case upMirrored = 2
        case down = 3
        case downMirrored = 4
        case leftMirrored = 5
        case right = 6
        case rightMirrored = 7
        case left = 8
    }
}
