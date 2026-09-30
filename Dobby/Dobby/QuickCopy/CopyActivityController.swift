import ActivityKit
import Observation
import Foundation
import UIKit

@MainActor @Observable
final class CopyActivityController {
    var session: ProductCopySession?
    var message = "도우미를 시작하면 상품과 채널이 고정됩니다."
    var busy = false

    init() { refresh() }

    func refresh() {
        guard let saved = ProductCopyStore.load(),
              Activity<ProductCopyAttributes>.activities.contains(where: {
                  $0.attributes.sessionID == saved.id && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            session = nil
            ProductCopyStore.invalidate()
            return
        }
        session = saved
    }

    func start(channel: CopyChannel, mode: CopyExperimentMode) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities가 꺼져 있거나 지원되지 않습니다."; return
        }
        // 오래된 활동은 먼저 종료하여 이전 상품의 버튼이 남지 않도록 한다.
        ProductCopyStore.invalidate()
        for activity in Activity<ProductCopyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let next = ProductCopySession(id: UUID(), channel: channel, mode: mode,
                                      payload: .sample(for: channel), createdAt: Date())
        do {
            try ProductCopyStore.save(next)
            _ = try Activity.request(attributes: ProductCopyAttributes(sessionID: next.id, channelName: channel.title, mode: mode),
                                     content: ActivityContent(state: .init(), staleDate: next.createdAt.addingTimeInterval(8 * 3600)), pushType: nil)
            session = next
            message = "\(channel.title) · \(mode.title) 시작"
            CopyJournal.append(message)
        } catch {
            ProductCopyStore.invalidate(); session = nil
            message = "시작 실패: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        ProductCopyStore.invalidate(); session = nil
        for activity in Activity<ProductCopyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        busy = false
        message = "도우미를 종료했습니다. 클립보드는 유지됩니다."
        CopyJournal.append("도우미 종료")
    }
}

import SwiftUI

struct CopyActivitySetupView: View {
    @State private var controller = CopyActivityController()
    @State private var channel: CopyChannel = .fruits
    @State private var mode: CopyExperimentMode = .foreground
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("실험 전 준비") {
                Button("기준값 BASELINE 복사") {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": "BASELINE"]], options: [.localOnly: true])
                    CopyJournal.append("기준값 BASELINE 쓰기 실행")
                }
                Text("외부 입력란에서 BASELINE이 아닌 선택한 상품 값이 붙는지 확인하세요. 버튼 실행만으로 복사 성공을 판정하지 않습니다.").font(.caption)
            }
            Section("도우미 설정") {
                Picker("채널", selection: $channel) {
                    ForEach(CopyChannel.allCases) { Text($0.title).tag($0) }
                }
                Picker("실행 방식", selection: $mode) {
                    ForEach(CopyExperimentMode.allCases) { Text($0.title).tag($0) }
                }
                Text("직접 복사는 백그라운드 쓰기 실험입니다. 앱 경유는 우리 앱에서 복사한 뒤 직접 돌아가거나 서비스 링크를 엽니다.").font(.caption)
                Button("복사 도우미 시작") { Task { await controller.start(channel: channel, mode: mode) } }
                    .disabled(controller.busy || controller.session != nil)
            }.disabled(controller.busy)
            Section("현재 상태") {
                if let session = controller.session {
                    Text("\(session.channel.title) · \(session.mode.title)")
                    Text("설정을 바꾸려면 종료 후 다시 시작하세요.").font(.caption)
                }
                Text(controller.message)
                Button("상태 새로고침") { controller.refresh() }
                Button("도우미 종료", role: .destructive) { Task { await controller.stop() } }
                    .disabled(controller.busy)
            }
            Section("확인 방법") {
                Text("후르츠 작성 화면 → Island 길게 누르기 → 복사 항목 선택 → 입력란 붙여넣기. 앱 경유 모드는 우리 앱을 거칩니다. 링크 재열기는 작성 화면 복귀를 보장하지 않습니다.")
                NavigationLink("기기 검증 결과") { QuickCopyResultsView() }
            }
        }
        .navigationTitle("Dynamic Island 도우미")
        .onChange(of: scenePhase) { _, phase in if phase == .active { controller.refresh() } }
    }
}
