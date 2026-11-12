import SwiftUI

struct Cafe24ConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: (String) -> Void
    @State private var mallID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("처음이신가요?")
                .font(.subheadline)
            Text("가지고 계신 카페24 계정과 연결할게요")
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("먼저 카페24 ID를 입력하고 아래 버튼을 눌러\n계정 연결을 완료해주세요.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
                .frame(height: 102)

            Cafe24MallIDField(mallID: $mallID)

            Spacer()
                .frame(minHeight: 325)

            Button { onConnect(normalizedMallID) } label: {
                HStack(spacing: 10) {
                    Image("Cafe24Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                    Text("카페24 계정 연결하기")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color(.label), in: RoundedRectangle(cornerRadius: 60))
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .background(Color(.brandNeutral50).ignoresSafeArea())
    }

    private var normalizedMallID: String {
        mallID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
