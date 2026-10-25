import SwiftUI

struct Cafe24ConnectionView: View {
    let isLoading: Bool
    let errorMessage: String?
    let onConnect: (String) -> Void
    let onRefresh: () -> Void
    @State private var isShowingMallIDInput = false
    @State private var mallID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("처음이신가요?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("먼저 카페24 계정과\n연결이 필요해요")
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text("카페24 계정과 연결을 완료하면\n상품을 자동으로 업로드할 수 있어요")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 92)

                VStack(spacing: 16) {
                    Text("아래 버튼을 누르고, 카페24 계정으로\n로그인해주세요")
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)

                    Button { isShowingMallIDInput = true } label: {
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
                    .background(Color(.label), in: RoundedRectangle(cornerRadius: 12))
                    .disabled(isLoading)
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
        .sheet(isPresented: $isShowingMallIDInput) {
            Cafe24MallIDInputView(
                mallID: $mallID,
                isLoading: isLoading,
                onConnect: {
                    onConnect(mallID)
                    isShowingMallIDInput = false
                }
            )
            .presentationDetents([.height(280)])
        }
    }
}

private struct Cafe24MallIDInputView: View {
    @Binding var mallID: String
    let isLoading: Bool
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("쇼핑몰 ID")
                        .font(.subheadline.weight(.semibold))
                    TextField("예: myshop", text: $mallID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .exportTextFieldStyle()
                    Text("쇼핑몰 주소의 .cafe24.com 앞부분을 입력해 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: onConnect) {
                    Text("카페24에서 연결하기")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color(.brandMain), in: Capsule())
                .disabled(isLoading || normalizedMallID.isEmpty)
                .opacity(normalizedMallID.isEmpty ? 0.45 : 1)
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.brandNeutral50))
            .navigationTitle("쇼핑몰 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private var normalizedMallID: String {
        mallID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

