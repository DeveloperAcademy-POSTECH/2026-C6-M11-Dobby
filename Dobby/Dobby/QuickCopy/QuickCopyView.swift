import SwiftUI
import UniformTypeIdentifiers

struct QuickCopyView: View {
    @State private var channel: CopyChannel = .fruits
    @State private var message = "복사할 항목을 선택하세요"
    @State private var copied: Set<String> = []
    private var payload: ProductCopyPayload { .sample(for: channel) }

    var body: some View {
        List {
            NavigationLink("Dynamic Island 복사 도우미") { CopyActivitySetupView() }
            NavigationLink("기기 검증 결과") { QuickCopyResultsView() }
            Section("샘플 상품 · 실제 제공된 본문") {
                Text(payload.productName).font(.headline)
                Picker("내보낼 채널", selection: $channel) {
                    ForEach(CopyChannel.allCases) { Text($0.title).tag($0) }
                }
                Text("후르츠 우선 검증 · Instagram은 후속 비교용입니다.").font(.caption)
            }
            Section("빠른 복사") {
                ForEach(ProductCopyField.allCases) { field in
                    DisclosureGroup(field.title) {
                        Text(payload.value(for: field)).font(.callout).textSelection(.enabled)
                    }
                    copyButton(field.title, value: payload.value(for: field), key: field.rawValue)
                }
                Text("실측 전체는 하나의 문자열입니다. 개별 입력란에는 아래 숫자를 각각 복사하세요.").font(.caption)
            }
            Section("개별 입력란용 숫자") {
                copyButton(channel == .fruits ? "가격 · 56000" : "기본 가격 · 65000", value: payload.price, key: "price")
                if channel == .instagram {
                    copyButton("팔로우 가격 · 55000", value: "55000", key: "discount")
                }
                copyButton("총장 · 59", value: payload.length, key: "length")
                copyButton("허리 단면 · 43", value: payload.waist, key: "waist")
                copyButton("허벅지 단면 · 32", value: payload.thigh, key: "thigh")
            }
            Section {
                Text("체크는 복사 실행 이력이며 외부 붙여넣기 완료가 아닙니다. 다른 항목을 복사하면 이전 클립보드 내용이 교체됩니다.").font(.caption)
            }
        }
        .navigationTitle("상품 정보 빠른 복사")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                .padding().background(.regularMaterial)
                .accessibilityIdentifier("quickCopy.feedback")
        }
    }

    private func copyButton(_ title: String, value: String, key: String) -> some View {
        let recordKey = "\(channel.rawValue).\(key)"
        return Button {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                message = "복사할 값이 없습니다"; return
            }
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
            copied.insert(recordKey)
            message = "\(channel.title) · \(title) 복사 실행"
            CopyJournal.append(message)
        } label: {
            Label(title, systemImage: copied.contains(recordKey) ? "checkmark.circle" : "doc.on.doc")
        }
        .accessibilityValue(copied.contains(recordKey) ? "복사 이력 있음, 다시 복사 가능" : "미실행")
    }
}

#Preview { NavigationStack { QuickCopyView() } }
