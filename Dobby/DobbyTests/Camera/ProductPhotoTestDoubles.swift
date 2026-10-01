//
//  ProductPhotoTestDoubles.swift
//  DobbyTests
//
//  Created by mason on 9/30/26.
//

import Foundation
@testable import Dobby

@MainActor
final class ProductPhotoCaptureStub: CaptureProviding {
    var nextAsset: CapturedAsset?
    var failure: CameraFailure?
    var suspend = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        if suspend {
            // 취소를 무시하는 장치 응답을 재현한다.
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }
        if let failure { throw failure }
        return nextAsset ?? CapturedAsset(
            id: UUID(), sessionID: sessionID, garmentID: garmentID,
            purpose: .detail, capturedAt: Date(), source: .mockPlaceholder
        )
    }

    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func complete() {
        pending?.resume()
        pending = nil
    }
}
