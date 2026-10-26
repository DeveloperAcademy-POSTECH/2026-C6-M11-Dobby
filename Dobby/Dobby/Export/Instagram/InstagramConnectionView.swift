import SwiftUI

struct InstagramConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: () -> Void
    let onRefresh: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("처음이신가요?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("먼저 인스타그램 프로페셔널 계정과\n연결이 필요해요")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("인스타그램을 열고, 프로페셔널 계정으로\n연결을 완료하면 자동으로 업로드할 수 있어요")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 92)

                VStack(spacing: 16) {
                    Text("인스타그램 계정을 연결해 주세요")
                        .font(.body.weight(.medium))

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
                    .background(Color(.label), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(isLoading)

                    Button("프로페셔널 계정으로 어떻게 설정하나요?") {
                        guard let url = URL(string: "https://help.instagram.com/502981923235522") else { return }
                        openURL(url)
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .underline()
                }
                .frame(maxWidth: .infinity)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }

                Spacer(minLength: 72)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
        }
        .background(Color(.brandNeutral50).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            Button("연결을 완료했어요", action: onRefresh)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 62)
                .foregroundStyle(.white)
                .background(Color(.brandMain), in: Capsule())
                .padding(.horizontal, 33)
                .padding(.vertical, 16)
                .background(Color(.brandNeutral50))
                .disabled(isLoading)
        }
    }
}
