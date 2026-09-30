import SwiftUI

struct ShortcutCopySetupSection: View {
    private let testValue = "FF-A-56000"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("처음 한 번만 설정해주세요", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Text("다이나믹 아일랜드에서 복사하려면 Apple 단축어가 클립보드에 내용을 넣어줘야 해요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                instruction(1, "단축어 앱에서 새 단축어를 만들어주세요")
                instruction(2, "이름을 ‘\(ShortcutCopyURLBuilder.shortcutName)’로 설정해주세요")
                instruction(3, "‘클립보드에 복사’ 동작을 추가해주세요")
                instruction(4, "복사할 내용으로 ‘단축어 입력’을 선택해주세요")
            }

            Link(destination: ShortcutCopyURLBuilder.shortcutsAppURL) {
                Label("단축어 앱 열기", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("shortcut.setup.open")

            if let testURL = ShortcutCopyURLBuilder.url(for: testValue) {
                Link(destination: testURL) {
                    Label("테스트 문구 복사", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("shortcut.setup.test")
            }

            Text("테스트 값: \(testValue)\n버튼을 누른 뒤 메모 앱에 붙여넣어 확인해주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Color.orange.opacity(0.25), in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ShortcutCopySetupSection()
        .padding()
}
