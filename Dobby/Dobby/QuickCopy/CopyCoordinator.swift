import SwiftUI
import ActivityKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class CopyCoordinator {
    var message = "복사 요청을 기다리고 있습니다"
    var copiedValue = ""
    var destination: URL?
    var opening = false
    private var pending: CopyRequest?
    private var gate = CopyRequestGate()

    func receive(_ url: URL) {
        guard let request = CopyRoute.parse(url) else {
            message = "올바르지 않은 복사 링크입니다"; return
        }
        guard !opening, pending == nil, gate.accept(request) else { return }
        pending = request
        destination = nil; copiedValue = ""
        message = "앱 활성화를 기다리고 있습니다"
        CopyJournal.append("앱 경유 링크 수신 · \(request.field.title)")
    }

    func processIfActive(_ phase: ScenePhase) {
        guard phase == .active, UIApplication.shared.applicationState == .active,
              let request = pending else { return }
        pending = nil // 활성화 알림이 반복되어도 한 번만 실행
        guard let session = ProductCopyStore.load(), session.id == request.sessionID,
              session.mode != .direct,
              Activity<ProductCopyAttributes>.activities.contains(where: {
                  $0.attributes.sessionID == session.id && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            message = "종료되었거나 만료된 도우미입니다. 새로 시작하세요."
            CopyJournal.append("앱 경유 요청 거절 · 유효한 활동 없음")
            return
        }
        let value = session.payload.value(for: request.field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "복사할 값이 없습니다"; return
        }
        CopyJournal.append("앱 활성화 확인 · \(session.channel.title)")
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
        copiedValue = value
        message = "\(request.field.title) 실행 · 작성 중인 앱으로 직접 돌아가 붙여넣으세요."
        CopyJournal.append("앱 경유 쓰기 실행 · \(request.field.title)")
        if session.mode == .foregroundAndOpen {
            destination = session.channel.destination
            openDestination()
        }
    }

    func openDestination() {
        guard !opening, let destination else { return }
        opening = true
        UIApplication.shared.open(destination) { [weak self] accepted in
            Task { @MainActor in
                guard let self else { return }
                self.opening = false
                self.message = accepted ? "복사 실행 · 서비스 링크 열기 요청 수락. 기존 작성 화면 유지 여부를 확인하세요." : "복사는 실행했지만 서비스 링크를 열지 못했습니다. 다시 열거나 직접 복귀하세요."
                CopyJournal.append("서비스 링크 열기 요청 \(accepted ? "수락" : "거절") · 기존 작성 탭 복귀는 미검증")
            }
        }
    }
}

struct CopyRequestView: View {
    let coordinator: CopyCoordinator
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Text(coordinator.message).accessibilityIdentifier("quickCopy.routeStatus")
            if !coordinator.copiedValue.isEmpty {
                DisclosureGroup("이번에 복사한 값") { Text(coordinator.copiedValue).textSelection(.enabled) }
            }
            if coordinator.destination != nil {
                Button("서비스 링크 다시 열기") { coordinator.openDestination() }.disabled(coordinator.opening)
            }
            Text("앱 전환으로 기존 후르츠 작성 화면에 직접 돌아갈 수 있습니다. 링크로 다시 열면 홈이나 새 화면이 열릴 수 있습니다.").font(.caption)
            NavigationLink("도우미 설정") { CopyActivitySetupView() }
            NavigationLink("기기 검증 결과") { QuickCopyResultsView() }
        }
        .navigationTitle("상품 정보 복사")
        .onAppear { coordinator.processIfActive(phase) }
    }
}
