//
//  CaptureProcessing.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// Camera-side seam only. An AVFoundation implementation will be added in a later step.
@MainActor
protocol CaptureProviding {
    func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset
}

/// Provisional camera-facing contract, NOT Ichi's ML or Mugu's LiDAR implementation.
/// Adapters must return the input captureID and support caller cancellation.
/// RGB/depth synchronization and shared camera-session ownership remain unagreed.
@MainActor
protocol CaptureProcessing {
    func process(_ asset: CapturedAsset) async throws -> ProcessingResult
}
