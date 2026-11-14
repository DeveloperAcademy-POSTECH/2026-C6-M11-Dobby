import SwiftUI

private enum ConnectedAccountTextStyle {
    static let titleFont = Font.custom("Pretendard-Medium", fixedSize: 16)
    static let accountFont = Font.custom("Pretendard-Medium", fixedSize: 14)
    static let titleTracking: CGFloat = -0.14
    static let accountTracking: CGFloat = -0.12
}

struct ConnectedAccountText: View {
    let title: String
    let account: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(ConnectedAccountTextStyle.titleFont)
                .tracking(ConnectedAccountTextStyle.titleTracking)
                .foregroundStyle(SettingsStyle.primaryText)
                .lineLimit(1)

            if let account {
                Text(account)
                    .font(ConnectedAccountTextStyle.accountFont)
                    .tracking(ConnectedAccountTextStyle.accountTracking)
                    .foregroundStyle(SettingsStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

#Preview {
    ConnectedAccountText(
        title: "인스타그램 계정 연결 완료",
        account: "@dobby"
    )
    .padding(20)
    .background(SettingsStyle.background)
}
