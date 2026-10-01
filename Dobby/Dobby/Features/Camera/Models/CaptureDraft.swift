//
//  CaptureDraft.swift
//  Dobby
//
//  Created by mason on 9/28/26.
//

import Foundation

/// In-memory draft only; persistence and detail-photo collection are later work.
struct CaptureDraft: Equatable {
    let sessionID: UUID
    let garmentID: UUID
    var measurement: CapturedAsset?
    var processingResult: ProcessingResult?

    init(sessionID: UUID = UUID(), garmentID: UUID = UUID()) {
        self.sessionID = sessionID
        self.garmentID = garmentID
    }
}
