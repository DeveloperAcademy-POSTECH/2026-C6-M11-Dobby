import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct QuickCopyResultsView: View {
    @State private var mode: CopyExperimentMode = .foreground
    @State private var channel: CopyChannel = .fruits
    @State private var field: ProductCopyField = .productName
    @State private var result = "미검증"
    @State private var draft = "미확인"
    @State private var screen = "미확인"
    @State private var login = "미확인"
    @State private var actual = ""
    @State private var device = ""
    @State private var note = ""
    @State private var moves = 0
    @State private var entries: [String] = []
    @State private var feedback = ""
    @State private var confirmClear = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Form {
            Section("후르츠 기기 검증 · Instagram 후속 비교") {
                Picker("채널", selection: $channel) { ForEach(CopyChannel.allCases) { Text($0.title).tag($0) } }
                Picker("실행 방식", selection: $mode) { ForEach(CopyExperimentMode.allCases) { Text($0.title).tag($0) } }
                Picker("항목", selection: $field) { ForEach(ProductCopyField.allCases) { Text($0.title).tag($0) } }
                TextField("기기 모델 / 대상 앱 버전", text: $device)
                TextField("실제 붙여넣은 값 또는 차이", text: $actual, axis: .vertical)
                Picker("결과", selection: $result) {
                    ForEach(["미검증", "성공", "일부 성공", "실패", "미지원"], id: \.self) { Text($0).tag($0) }
                }
                Picker("복귀한 화면", selection: $screen) {
                    ForEach(["미확인", "기존 작성 화면", "홈/새 화면", "브라우저/새 탭"], id: \.self) { Text($0).tag($0) }
                }
                Picker("작성 내용", selection: $draft) {
                    ForEach(["미확인", "유지", "일부 유실", "유실"], id: \.self) { Text($0).tag($0) }
                }
                Picker("로그인", selection: $login) {
                    ForEach(["미확인", "유지", "재로그인 필요"], id: \.self) { Text($0).tag($0) }
                }
                Stepper("앱 이동 \(moves)회", value: $moves, in: 0...100)
                TextField("메모 · 가격/실측 개별 복사 결과 등", text: $note, axis: .vertical)
                Button("관찰 결과 저장") {
                    CopyJournal.append("수동 [\(result)] \(channel.title) / \(mode.title) / \(field.title) · iOS \(UIDevice.current.systemVersion), \(device) · 관찰=\(actual) · 화면=\(screen), 초안=\(draft), 로그인=\(login), 이동=\(moves) · \(note)")
                    reload(); feedback = "결과를 저장했습니다"
                }
                Text("시험 상품 정보만 기록하세요. 미기록 항목은 미검증입니다. 가격과 세 실측 입력란은 본 앱의 개별 복사를 사용해 비교하세요.").font(.caption)
            }
            Section("저장된 기록 · 최대 300건") {
                Button("기록 새로고침") { reload() }
                Button("보고서 복사") {
                    let report = "# 상품 정보 빠른 복사 #5\n쓰기 실행 ≠ 외부 수신 성공. 미기록 조건은 미검증.\n" + CopyJournal.entries().reversed().joined(separator: "\n")
                    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: report]], options: [.localOnly: true])
                    feedback = "보고서로 클립보드를 교체했습니다"
                }
                Text("보고서 복사는 직전 상품 클립보드를 교체합니다. 기록은 앱을 종료해도 유지됩니다.").font(.caption)
                Text(feedback).font(.caption)
                Button("기록 삭제", role: .destructive) { confirmClear = true }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in Text(entry).font(.caption).textSelection(.enabled) }
            }
        }
        .navigationTitle("빠른 복사 검증 결과")
        .onAppear { reload() }
        .onChange(of: phase) { _, value in if value == .active { reload() } }
        .alert("기록을 삭제할까요?", isPresented: $confirmClear) {
            Button("삭제", role: .destructive) { CopyJournal.clear(); reload() }
            Button("취소", role: .cancel) {}
        } message: { Text("기록만 지웁니다. 현재 활동과 클립보드는 유지됩니다.") }
    }
    private func reload() { entries = CopyJournal.entries() }
}
