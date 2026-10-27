import SwiftUI

struct Cafe24MallIDField: View {
    @Binding var mallID: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ChakTextField(
                label: "카페24 ID",
                text: $mallID,
                placeholder: "카페24 ID를 적어주세요",
                isRequired: true
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            if !mallID.isEmpty {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255),
                        lineWidth: 1
                    )
                    .frame(height: 56)
                    .allowsHitTesting(false)
            }

            Cafe24MallIDSuffix()
                .frame(height: 56)
                .padding(.trailing, 20)
        }
    }
}

private struct Cafe24MallIDSuffix: View {
    var body: some View {
        Text(".cafe24.com")
            .font(.custom("Pretendard-Medium", fixedSize: 16))
            .tracking(-0.16)
            .foregroundStyle(Color(.brandNeutral900))
            .padding(.leading, 12)
            .background(Color(.brandNeutral100))
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
