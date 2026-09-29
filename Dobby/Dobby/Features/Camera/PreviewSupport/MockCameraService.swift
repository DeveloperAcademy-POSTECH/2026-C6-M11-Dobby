//
//  MockCameraService.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// Explicitly injected demo provider. Never requests permission, opens a camera, or saves a file.
struct MockCameraService: CaptureProviding {
    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
        try Task.checkCancellation()
        return CapturedAsset(
            id: UUID(), sessionID: sessionID, garmentID: garmentID,
            purpose: .measurement, capturedAt: Date(), source: .mockPlaceholder
        )
    }
}
