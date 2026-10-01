//
//  CameraPermissionTests.swift
//  DobbyTests
//
//  Created by mason on 9/29/26.
//

import AVFoundation
import Testing
@testable import Dobby

@MainActor
struct CameraPermissionTests {
    @Test(arguments: [AVAuthorizationStatus.authorized, .denied, .restricted])
    func decidedPermissionDoesNotPromptAgain(status: AVAuthorizationStatus) async {
        let authorizer = PermissionStub(status: status)
        let permission = CameraPermission(authorizer: authorizer)
        await permission.requestAccess()
        #expect(permission.status == status)
        #expect(authorizer.requestCount == 0)
        #expect(!permission.isRequesting)
    }

    @Test(arguments: [AVAuthorizationStatus.authorized, .denied])
    func firstRequestUsesCurrentSystemAnswer(answer: AVAuthorizationStatus) async {
        let authorizer = PermissionStub(status: .notDetermined)
        authorizer.answer = answer
        let permission = CameraPermission(authorizer: authorizer)
        await permission.requestAccess()
        #expect(permission.status == answer)
        #expect(authorizer.requestCount == 1)
        #expect(!permission.isRequesting)
    }

    @Test func refreshDetectsSettingsChangesWithoutRequesting() {
        let authorizer = PermissionStub(status: .denied)
        let permission = CameraPermission(authorizer: authorizer)
        for status: AVAuthorizationStatus in [.authorized, .denied, .restricted] {
            authorizer.status = status
            permission.refresh()
            #expect(permission.status == status)
        }
        #expect(authorizer.requestCount == 0)
    }

    @Test func requestRechecksPermissionBeforeShowingPrompt() async {
        let authorizer = PermissionStub(status: .notDetermined)
        let permission = CameraPermission(authorizer: authorizer)
        authorizer.status = .denied
        await permission.requestAccess()
        #expect(permission.status == .denied)
        #expect(authorizer.requestCount == 0)
    }

    @Test func repeatedTapsCannotStartOverlappingRequests() async {
        let authorizer = PermissionStub(status: .notDetermined)
        authorizer.suspends = true
        let permission = CameraPermission(authorizer: authorizer)
        let request = Task { await permission.requestAccess() }
        await authorizer.waitUntilStarted()
        #expect(permission.isRequesting)
        await permission.requestAccess()
        #expect(authorizer.requestCount == 1)
        authorizer.complete()
        await request.value
        #expect(permission.status == .authorized)
        #expect(!permission.isRequesting)
    }
}

@MainActor
private final class PermissionStub: CameraAuthorizing {
    var status: AVAuthorizationStatus
    var answer: AVAuthorizationStatus = .authorized
    var requestCount = 0
    var suspends = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(status: AVAuthorizationStatus) { self.status = status }

    func requestAccess() async {
        requestCount += 1
        if suspends {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }
        status = answer
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
