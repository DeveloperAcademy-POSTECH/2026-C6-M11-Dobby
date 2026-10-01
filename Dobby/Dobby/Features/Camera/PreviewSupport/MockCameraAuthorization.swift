//
//  MockCameraAuthorization.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

import AVFoundation
import SwiftUI

/// Preview only: never requests system permission.
final class MockCameraAuthorization: CameraAuthorizing {
    var status: AVAuthorizationStatus

    init(status: AVAuthorizationStatus = .authorized) {
        self.status = status
    }

    func requestAccess() async { status = .authorized }
}

#Preview("최초 권한 요청") {
    CameraPermissionGate(permission: CameraPermission(authorizer: MockCameraAuthorization(status: .notDetermined))) {
        Text("권한 허용 완료")
    }.padding()
}

#Preview("권한 거부") {
    CameraPermissionGate(permission: CameraPermission(authorizer: MockCameraAuthorization(status: .denied))) {
        Text("권한 허용 완료")
    }.padding()
}

#Preview("사용 제한") {
    CameraPermissionGate(permission: CameraPermission(authorizer: MockCameraAuthorization(status: .restricted))) {
        Text("권한 허용 완료")
    }.padding()
}
