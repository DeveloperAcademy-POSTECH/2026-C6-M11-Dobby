import SwiftUI

struct InstagramConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("처음이신가요?")
                    .font(.subheadline)
                Text("먼저 인스타그램 프로페셔널 계정과\n연결이 필요해요")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("인스타그램을 열고, 프로페셔널 계정으로\n연결을 완료하면 자동으로 업로드할 수 있어요")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                VStack(spacing: 18) {
                    Text("아래 버튼을 누르고, 프로페셔널 계정으로\n로그인해주세요")
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)

                    Button(action: onConnect) {
                        HStack(spacing: 10) {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image("InstagramLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                            }
                            Text("인스타그램 계정 연결하기")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color(.label), in: RoundedRectangle(cornerRadius: 60))
                    .disabled(isLoading)

                    Button("프로페셔널 계정으로 어떻게 설정하나요?") {
                        guard let url = URL(
                            string: "https://www.facebook.com/business/help/347556992775908?id=419087378825961"
                        ) else { return }
                        openURL(url)
                    }
                    .font(.caption)
                    .underline()
                    .foregroundStyle(Color(.brandNeutral700))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .background(Color(.brandNeutral50).ignoresSafeArea())

    }
}
