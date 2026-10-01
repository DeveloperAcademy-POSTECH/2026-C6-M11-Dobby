//
//  CameraModel.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

import Foundation
import Observation

/// Owns capture data and validation, never screen routes or presentation copy.
@MainActor
@Observable
final class CameraModel {
    private(set) var draft = CaptureDraft()

    @ObservationIgnored private let captureProvider: any CaptureProviding
    @ObservationIgnored private let processor: any CaptureProcessing
    @ObservationIgnored private var requestID: UUID?

    var canHandoff: Bool {
        guard let asset = draft.measurement, let result = draft.processingResult else { return false }
        return result.captureID == asset.id && result.outcome == .ready
    }

    init(captureProvider: any CaptureProviding, processor: any CaptureProcessing) {
        self.captureProvider = captureProvider
        self.processor = processor
    }

    func capture() async throws {
        let request = try beginRequest()
        defer { endRequest(request) }
        let asset = try await captureProvider.capture(
            sessionID: draft.sessionID, garmentID: draft.garmentID
        )
        try validateRequest(request)
        guard asset.sessionID == draft.sessionID, asset.garmentID == draft.garmentID,
              asset.purpose == .measurement else { throw CameraFailure.mismatchedCapture }
        draft.measurement = asset
        draft.processingResult = nil
    }

    func process() async throws {
        guard let asset = draft.measurement else { throw CameraFailure.missingCapture }
        let request = try beginRequest()
        defer { endRequest(request) }
        draft.processingResult = nil
        let result = try await processor.process(asset)
        try validateRequest(request)
        guard result.captureID == asset.id else { throw CameraFailure.mismatchedResult }
        draft.processingResult = result
    }

    /// Discards this in-memory demo and invalidates any late response.
    func reset() {
        requestID = nil
        draft = CaptureDraft()
    }

    private func beginRequest() throws -> UUID {
        try Task.checkCancellation()
        guard requestID == nil else { throw CameraFailure.operationInProgress }
        let request = UUID()
        requestID = request
        return request
    }

    private func validateRequest(_ request: UUID) throws {
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
    }

    private func endRequest(_ request: UUID) {
        if requestID == request { requestID = nil }
    }
}
