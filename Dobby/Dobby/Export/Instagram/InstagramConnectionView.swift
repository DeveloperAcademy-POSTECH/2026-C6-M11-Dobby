import SwiftUI

struct InstagramConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InstagramConnectionHeader()

            Spacer(minLength: 0)

            InstagramConnectionActions(isLoading: isLoading, onConnect: onConnect)
        }
        .frame(maxWidth: 362, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 38)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(.brandNeutralWhite).ignoresSafeArea())
    }
}

private struct InstagramConnectionHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            Text("먼저 인스타그램 프로페셔널\n계정과 연결이 필요해요")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color(.brandNeutralBlack))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            InstagramConnectionInstructions()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct InstagramConnectionInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("인스타그램을 열고, 프로페셔널 계정으로\n연결을 완료하면 자동으로 업로드할 수 있어요")

            Text("아래 버튼을 누르고, 프로페셔널 계정으로\n로그인해주세요")
        }
        .font(.body.weight(.regular))
        .foregroundStyle(Color(.brandNeutral600))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InstagramConnectionActions: View {
    let isLoading: Bool
    let onConnect: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button(action: onConnect) {
                HStack(alignment: .center, spacing: 12) {
                    if isLoading {
                        ChakLoadingIndicator(tint: Color(.brandNeutralWhite))
                            .frame(width: 30, height: 30)
                    } else {
                        Image("InstagramLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                    }

                    Text("인스타그램 계정 연결하기")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62)
                .background(Color(.brandNeutral950), in: RoundedRectangle(cornerRadius: 60))
                .contentShape(RoundedRectangle(cornerRadius: 60))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(.brandNeutralWhite))
            .allowsHitTesting(!isLoading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("인스타그램 계정 연결하기")
            .accessibilityValue(isLoading ? "연결 중" : "연결 전")

            Button("프로페셔널 계정으로 어떻게 설정하나요?") {
                guard let url = URL(
                    string: "https://help.instagram.com/502981923235522"
                ) else { return }
                openURL(url)
            }
            .font(.caption.weight(.regular))
            .underline()
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(.brandNeutral700))
            .frame(maxWidth: .infinity, alignment: .top)
            .accessibilityHint("프로페셔널 계정 설정 안내 웹페이지를 엽니다.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)

    }
}

#Preview("계정 연결 전") {
    InstagramConnectionView(isLoading: false, errorMessage: nil, onConnect: {})
}

#Preview("계정 연결 중") {
    InstagramConnectionView(isLoading: true, errorMessage: nil, onConnect: {})
}

#Preview("계정 연결 · 제목과 안내", traits: .sizeThatFitsLayout) {
    InstagramConnectionHeader()
        .frame(width: 362)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("계정 연결 · 안내 문구", traits: .sizeThatFitsLayout) {
    InstagramConnectionInstructions()
        .frame(width: 362)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("계정 연결 · 버튼", traits: .sizeThatFitsLayout) {
    InstagramConnectionActions(isLoading: false, onConnect: {})
        .frame(width: 362)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("계정 연결 · 로딩 버튼", traits: .sizeThatFitsLayout) {
    InstagramConnectionActions(isLoading: true, onConnect: {})
        .frame(width: 362)
        .padding()
        .background(Color(.brandNeutralWhite))
}
