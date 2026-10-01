import SwiftUI

struct ShortcutCopySetupSection: View {
    private let testValue = "FF-A-56000"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("앱 경유 복사 실기기 테스트", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.headline)
                Text("다이나믹 아일랜드에서 Dobby를 잠깐 열어 복사한 뒤 후르츠패밀리로 다시 돌아가는 방식을 검증합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Link(destination: ForegroundCopyURLBuilder.testURL) {
                Label("Dobby를 경유해 테스트 복사", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityIdentifier("copy.relay.test")

            Text("테스트 값: \(testValue)\n버튼을 누른 뒤 메모 앱에 붙여넣어 확인해주세요.")
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
