//
//  CameraAuthorizing.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

import AVFoundation

@MainActor
protocol CameraAuthorizing {
    var status: AVAuthorizationStatus { get }
    func requestAccess() async
}

struct SystemCameraAuthorization: CameraAuthorizing {
    var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }
}
