//
//  CameraFailure.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

enum CameraFailure: Error, Equatable {
    case captureFailed
    case processingFailed
    case mismatchedCapture
    case mismatchedResult
    case missingCapture
    case operationInProgress
}
