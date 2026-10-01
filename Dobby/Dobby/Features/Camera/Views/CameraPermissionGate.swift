//
//  CameraPermissionGate.swift
//  Dobby
//
//  Created by mason on 9/29/26.
//

import SwiftUI
import AVFoundation
import UIKit

/// The first request uses iOS's permission alert (Figma 452:1239).
/// Denied/restricted recovery screens supplement the current Hi-Fi design.
struct CameraPermissionGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var permission: CameraPermission
    @State private var settingsOpenFailed = false
    private let content: Content

    init(permission: CameraPermission, @ViewBuilder content: () -> Content) {
        _permission = State(initialValue: permission)
        self.content = content()
    }

    var body: some View {
        Group {
            if permission.status == .authorized {
                content
            } else {
                VStack(spacing: 20) {
                    explanation
                    if permission.isRequesting {
                        ProgressView("카메라 권한 응답을 기다리고 있어요")
                    } else {
                        action
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.vertical, 32)
            }
        }
        .task { permission.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permission.refresh() }
        }
        .alert("설정을 열 수 없어요", isPresented: $settingsOpenFailed) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("설정 앱에서 Dobby의 카메라 접근을 허용한 뒤 돌아와 주세요.")
        }
    }

    @ViewBuilder
    private var explanation: some View {
        switch permission.status {
        case .notDetermined:
            Text("카메라 접근을 허용해 주세요").font(.title2.bold())
            Text("옷의 실측용 사진과 상품 상세 사진을 촬영하는 데 카메라를 사용해요.")
                .foregroundStyle(.secondary)
        case .denied:
            Text("카메라 접근이 꺼져 있어요").font(.title2.bold())
            Text("설정에서 Dobby의 카메라 접근을 켜 주세요. 앱으로 돌아오면 다시 확인해요.")
                .foregroundStyle(.secondary)
        case .restricted:
            Text("카메라 사용이 제한되어 있어요").font(.title2.bold())
            Text("스크린 타임 또는 기기 관리 설정을 확인해 주세요. 관리 중인 기기라면 관리자에게 문의해 주세요.")
                .foregroundStyle(.secondary)
        default:
            Text("카메라 권한을 확인할 수 없어요").font(.title2.bold())
            Text("다시 확인하거나 닫은 뒤 다시 시도해 주세요.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch permission.status {
        case .notDetermined:
            Button("카메라 접근 허용") { Task { await permission.requestAccess() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("camera.requestPermission")
        case .denied:
            Button("설정 열기") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else {
                    settingsOpenFailed = true
                    return
                }
                openURL(url) { accepted in settingsOpenFailed = !accepted }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("camera.openSettings")
        default:
            Button("권한 다시 확인", action: permission.refresh)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("camera.refreshPermission")
        }
    }
}
