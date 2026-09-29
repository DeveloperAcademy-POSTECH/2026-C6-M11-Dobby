//
//  ProcessingResult.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// Provisional result envelope. Landmark/depth/measurement types await owner agreement.
/// `ready` means processing finished, not that a seller verified the measurements.
struct ProcessingResult: Equatable, Sendable {
    let captureID: UUID
    let source: Source
    let outcome: Outcome
    /// Optional normalized score (0...1); nil means unavailable, never zero confidence.
    let confidence: Double?

    enum Source: String, Sendable {
        case mock
        case integrated
    }

    enum Outcome: String, Sendable {
        case ready
        case lowConfidence
        case unsupported
    }
}
