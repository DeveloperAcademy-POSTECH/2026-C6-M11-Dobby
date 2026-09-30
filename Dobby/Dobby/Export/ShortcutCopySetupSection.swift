import SwiftUI

struct ShortcutCopySetupSection: View {
    private let testValue = "FF-A-56000"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("App Shortcut 실기기 테스트", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                Text("Dobby가 복사 기능을 iPhone에 자동으로 등록했어요. 사용자가 단축어를 만들거나 추가할 필요는 없어요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let testURL = ShortcutCopyURLBuilder.testURL {
                Link(destination: testURL) {
                    Label("App Shortcut으로 테스트 복사", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("shortcut.setup.test")
            }

            Text("테스트 값: \(testValue)\n버튼을 누른 뒤 메모 앱에 붙여넣어 확인해주세요. 단축어를 찾을 수 없다는 안내가 나오면 그 문구도 알려주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

}

#Preview {
    ShortcutCopySetupSection()
        .padding()
}
