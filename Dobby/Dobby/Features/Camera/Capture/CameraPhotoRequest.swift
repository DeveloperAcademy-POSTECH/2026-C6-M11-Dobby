//
//  CameraPhotoRequest.swift
//  Dobby
//
//  Created by mason on 10/1/26.
//

import AVFoundation
import Foundation

/// 촬영 1회의 delegate. AVFoundation 콜백과 Task 취소는 lock으로 보호한다.
/// 최종 콜백까지 driver가 보관하며 continuation은 성공·실패·취소 중 한 번만 재개한다.
nonisolated final class CameraPhotoRequest: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var photoData: Data?
    private var processingFailed = false
    private let onFinished: @Sendable () -> Void

    init(onFinished: @escaping @Sendable () -> Void) { self.onFinished = onFinished }

    var isResolved: Bool { lock.withLock { result != nil } }

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        let finished: Result<Data, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let finished { continuation.resume(with: finished) }
    }

    func resolve(_ result: Result<Data, any Error>) {
        let pending = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Data, any Error>? }
            self.result = result
            photoData = nil
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let data = error == nil && !isResolved ? photo.fileDataRepresentation() : nil
        lock.withLock {
            guard result == nil else { return }
            photoData = data
            processingFailed = error != nil || data == nil
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: (any Error)?) {
        let completed: Result<Data, any Error> = lock.withLock {
            guard error == nil, !processingFailed, let photoData else { return .failure(CameraFailure.captureFailed) }
            return .success(photoData)
        }
        // 먼저 driver의 촬영 잠금을 해제한 다음 호출자를 깨운다.
        onFinished()
        resolve(completed)
    }
}
