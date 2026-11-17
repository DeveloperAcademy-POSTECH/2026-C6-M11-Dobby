import SwiftUI
import UIKit

struct Cafe24ConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: (String) -> Void
    @State private var mallID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Cafe24ConnectionHeader()

            Spacer()
                .frame(height: 102)

            Cafe24MallIDField(mallID: $mallID)

            Spacer()
                .frame(minHeight: 325)

            Button { onConnect(normalizedMallID) } label: {
                HStack(spacing: 10) {
                    if isLoading {
                        ChakLoadingIndicator(tint: Color(.brandNeutralWhite))
                            .frame(width: 30, height: 30)
                    } else {
                        Image("Cafe24Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                    }
                    Text("카페24 계정 연결하기")
                        .font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(Color(.label), in: RoundedRectangle(cornerRadius: 60))
                .contentShape(RoundedRectangle(cornerRadius: 60))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("카페24 계정 연결하기")
            .accessibilityValue(isLoading ? "연결 중" : "연결 전")
        }
        .frame(maxWidth: 362, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(.brandNeutralWhite).ignoresSafeArea())
    }

    private var normalizedMallID: String {
        mallID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct Cafe24ConnectionHeader: View {
    var body: some View {
        let font = UIFont(name: "Pretendard-Bold", size: 24) ?? .boldSystemFont(ofSize: 24)
        let lineSpacing = max(0, 32 - font.lineHeight)

        VStack(alignment: .leading, spacing: 48) {
            Text("가지고 계신 카페24 계정과 \n연결할게요")
                .font(.custom("Pretendard-Bold", fixedSize: 24))
                .tracking(-0.26)
                .lineSpacing(lineSpacing)
                .foregroundStyle(Color(.brandNeutralBlack))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("먼저 카페24 ID를 입력하고 아래 버튼을 눌러\n계정 연결을 완료해주세요.")
                .font(.body.weight(.regular))
                .foregroundStyle(Color(.brandNeutral600))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

#Preview("계정 연결 전") {
    Cafe24ConnectionView(
        isLoading: false,
        errorMessage: nil,
        onConnect: { _ in }
    )
}

#Preview("계정 연결 중") {
    Cafe24ConnectionView(
        isLoading: true,
        errorMessage: nil,
        onConnect: { _ in }
    )
}

#Preview("계정 연결 · 제목과 안내", traits: .sizeThatFitsLayout) {
    Cafe24ConnectionHeader()
        .frame(width: 362)
        .padding()
        .background(Color(.brandNeutralWhite))
}
