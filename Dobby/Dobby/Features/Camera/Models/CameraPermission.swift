//
//  CameraPermission.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

import AVFoundation
import Observation

/// Reads the system's current permission; never persists an assumed authorization.
@MainActor
@Observable
final class CameraPermission {
    private(set) var status: AVAuthorizationStatus
    private(set) var isRequesting = false
    @ObservationIgnored private let authorizer: any CameraAuthorizing

    init(authorizer: any CameraAuthorizing) {
        self.authorizer = authorizer
        status = authorizer.status
    }

    func refresh() {
        status = authorizer.status
    }

    func requestAccess() async {
        guard !isRequesting else { return }
        refresh()
        guard status == .notDetermined else { return }
        isRequesting = true
        defer { isRequesting = false }
        await authorizer.requestAccess()
        refresh()
    }
}
