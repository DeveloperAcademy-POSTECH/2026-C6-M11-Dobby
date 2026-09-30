import SwiftUI
import UIKit

private enum CopyDiagnosticCondition: String, CaseIterable, Identifiable {
    case immediately = "앱 전환 직후"
    case afterTenSeconds = "앱 전환 10초 후"
    case afterOneMinute = "앱 전환 1분 후"
    case afterForceQuit = "Dobby 강제 종료 후"
    case afterLock = "화면 잠금·해제 후"

    var id: String { rawValue }
}

private enum CopyDiagnosticTarget: String, CaseIterable, Identifiable {
    case notes = "메모 앱"
    case fruits = "후루츠패밀리"

    var id: String { rawValue }
}

struct QuickCopyDiagnosticsView: View {
    let product: ExportProduct
    let controller: CopyActivityController

    @Environment(\.scenePhase) private var scenePhase
    @State private var interactionMode = CopyInteractionMode.direct
    @State private var strategy = CopyWriteStrategy.setItemsLocalOnly
    @State private var condition = CopyDiagnosticCondition.immediately
    @State private var target = CopyDiagnosticTarget.notes
    @State private var token = ""
    @State private var status = "진단 활동을 시작해주세요."
    @State private var results: [CopyDiagnosticResult] = []
    @State private var manualResults: [String: String] = [:]

    var body: some View {
        Form {
            Section("테스트 설정") {
                Picker("아일랜드 동작", selection: $interactionMode) {
                    ForEach(CopyInteractionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("클립보드 방식", selection: $strategy) {
                    ForEach(CopyWriteStrategy.allCases) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                Picker("테스트 조건", selection: $condition) {
                    ForEach(CopyDiagnosticCondition.allCases) { condition in
                        Text(condition.rawValue).tag(condition)
                    }
                }
                Picker("붙여넣을 앱", selection: $target) {
                    ForEach(CopyDiagnosticTarget.allCases) { target in
                        Text(target.rawValue).tag(target)
                    }
                }
                Button("이 설정으로 진단 활동 시작") {
                    Task { await startDiagnostic() }
                }
                .disabled(controller.busy)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text(interactionDescription).font(.caption).foregroundStyle(.secondary)
            }

            if !token.isEmpty {
                Section("이번 테스트") {
                    LabeledContent("식별자", value: token)
                    Text("아일랜드에서 복사한 문장이 `[DOBBY-항목-\(token)]`으로 시작해야 이번 시도가 성공한 것입니다.")
                        .font(.caption)
                    if target == .fruits {
                        Button("후루츠패밀리 열기") { openFruits() }
                    } else {
                        Text("홈 화면이나 앱 전환기에서 메모 앱을 직접 열어주세요.")
                            .font(.caption)
                    }
                    Text(instruction).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("최근 실행 결과") {
                Button("결과 새로고침") { reload() }
                if results.isEmpty {
                    Text("아직 기록된 시도가 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(results.prefix(20)) { result in
                    diagnosticRow(result)
                }
            }

            Section("진단 보고서") {
                Button("보고서 복사") {
                    UIPasteboard.general.string = report
                    status = "진단 보고서를 복사했습니다."
                }
                Button("진단 기록 삭제", role: .destructive) {
                    ProductCopyStore.clearDiagnostics()
                    CopyDiagnosticManualStore.clear()
                    reload()
                }
            }
        }
        .navigationTitle("아일랜드 복사 진단")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private var instruction: String {
        switch condition {
        case .immediately: "대상 앱으로 이동한 직후 아일랜드 버튼을 누르세요."
        case .afterTenSeconds: "대상 앱으로 이동한 뒤 10초를 기다리고 아일랜드 버튼을 누르세요."
        case .afterOneMinute: "대상 앱으로 이동한 뒤 1분을 기다리고 아일랜드 버튼을 누르세요."
        case .afterForceQuit: "대상 앱으로 이동한 뒤 앱 전환기에서 Dobby를 종료하고 아일랜드 버튼을 누르세요."
        case .afterLock: "대상 앱으로 이동한 뒤 화면을 잠갔다가 해제하고 아일랜드 버튼을 누르세요."
        }
    }

    @MainActor
    private func startDiagnostic() async {
        let nextToken = String(UUID().uuidString.prefix(4))
        let started = await controller.start(
            product: product,
            writeStrategy: strategy,
            diagnosticToken: nextToken,
            diagnosticCondition: "\(interactionMode.title) · \(target.rawValue) · \(condition.rawValue)",
            interactionMode: interactionMode
        )
        if started {
            token = nextToken
            status = "진단 활동을 시작했습니다. 안내에 따라 대상 앱에서 테스트해주세요."
        } else {
            status = controller.errorMessage ?? "진단 활동을 시작하지 못했습니다."
        }
        reload()
    }

    private func openFruits() {
        UIApplication.shared.open(
            ExportChannel.fruitsFamily.destinationURL,
            options: [.universalLinksOnly: true]
        ) { accepted in
            if !accepted {
                Task { @MainActor in status = "후루츠패밀리를 직접 열어주세요." }
            }
        }
    }

    private var interactionDescription: String {
        switch interactionMode {
        case .direct:
            "현재 제품 방식입니다. 대상 앱 화면을 유지한 채 백그라운드에서 복사를 시도합니다."
        case .foreground:
            "이전 테크 바이어빌리티 방식입니다. 아일랜드 버튼이 Dobby를 열고, 활성화된 뒤 복사합니다. 이후 대상 앱으로 직접 돌아가세요."
        case .foregroundAndOpen:
            "이전 테크 바이어빌리티 방식입니다. Dobby에서 복사한 뒤 후루츠 링크를 다시 엽니다. 기존 작성 화면 유지 여부도 확인하세요."
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ result: CopyDiagnosticResult) -> some View {
        let key = result.id.uuidString
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result.diagnosticToken ?? String(result.id.uuidString.prefix(4))).font(.headline)
                Spacer()
                Text(result.writeVerified ? "코드 확인 성공" : "코드 확인 실패")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.writeVerified ? .green : .red)
            }
            Text("\(result.writeStrategy?.title ?? "이전 방식") · \(result.executionMode)")
                .font(.caption)
            Text("changeCount \(result.beforeChangeCount) → \(result.afterChangeCount) · 재조회 \(result.readBackMatches ? "일치" : "불일치") · \(result.elapsedMilliseconds)ms")
                .font(.caption).foregroundStyle(.secondary)
            if let condition = result.diagnosticCondition {
                Text(condition).font(.caption).foregroundStyle(.secondary)
            }
            Picker("실제 붙여넣기", selection: Binding(
                get: { manualResults[key] ?? "미확인" },
                set: { value in
                    manualResults[key] = value
                    CopyDiagnosticManualStore.save(manualResults)
                }
            )) {
                Text("미확인").tag("미확인")
                Text("성공").tag("성공")
                Text("실패").tag("실패")
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func reload() {
        results = ProductCopyStore.diagnostics()
        manualResults = CopyDiagnosticManualStore.load()
    }

    private var report: String {
        let lines = results.map { result in
            let manual = manualResults[result.id.uuidString] ?? "미확인"
            return "- \(result.createdAt.formatted()) | token=\(result.diagnosticToken ?? "-") | condition=\(result.diagnosticCondition ?? "-") | strategy=\(result.writeStrategy?.rawValue ?? "legacy") | mode=\(result.executionMode) | canForeground=\(result.canContinueInForeground) | change=\(result.beforeChangeCount)->\(result.afterChangeCount) | readBack=\(result.readBackMatches) | paste=\(manual)"
        }
        return (["# Dynamic Island Clipboard Diagnostics", "실제 붙여넣기 결과가 최종 판정 기준입니다."] + lines).joined(separator: "\n")
    }
}

@MainActor
private enum CopyDiagnosticManualStore {
    private static let key = "quickCopy.diagnostics.manual.v1"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ values: [String: String]) {
        UserDefaults.standard.set(values, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
