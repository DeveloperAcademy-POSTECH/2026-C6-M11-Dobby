import SwiftUI

struct Cafe24MallIDField: View {
    @Binding var mallID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("카페24 ID")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(.label))

            HStack(alignment: .center, spacing: 10) {
                TextField(
                    "",
                    text: $mallID,
                    prompt: Text("카페24 ID를 적어주세요")
                        .foregroundStyle(Color(red: 191 / 255, green: 191 / 255, blue: 191 / 255))
                )
                .font(.custom("Pretendard-Regular", fixedSize: 15))
                .tracking(-0.16)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("카페24 쇼핑몰 ID")
                .accessibilityHint("쇼핑몰 주소에서 .cafe24.com 앞부분만 입력합니다.")

                Cafe24MallIDSuffix()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct Cafe24MallIDSuffix: View {
    var body: some View {
        Text(".cafe24.com")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(.brandNeutralBlack))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview("상태 비교", traits: .sizeThatFitsLayout) {
    @Previewable @State var emptyMallID = ""
    @Previewable @State var enteredMallID = "Chak"

    HStack(spacing: 32) {
        Cafe24MallIDField(mallID: $emptyMallID)
        Cafe24MallIDField(mallID: $enteredMallID)
    }
    .padding(24)
    .frame(width: 820)
    .background(Color(.brandNeutralWhite))
}

#Preview("도메인 접미사", traits: .sizeThatFitsLayout) {
    Cafe24MallIDSuffix()
        .padding()
        .background(Color(.brandNeutralWhite))
}
