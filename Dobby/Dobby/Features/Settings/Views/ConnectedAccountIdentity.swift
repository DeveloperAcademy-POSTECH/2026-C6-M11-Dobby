import SwiftUI

struct ConnectedAccountIdentity: View {
    let imageName: String
    let title: String
    let account: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 15))

            ConnectedAccountText(title: title, account: account)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    ConnectedAccountIdentity(
        imageName: "InstagramLogo",
        title: "인스타그램 계정 연결 완료",
        account: "@dobby"
    )
    .padding(20)
    .background(SettingsStyle.background)
}
