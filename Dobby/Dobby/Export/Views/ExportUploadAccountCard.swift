import SwiftUI

struct ExportUploadAccountCard<Profile: View>: View {
    let accountLabel: String
    @ViewBuilder let profile: () -> Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이 계정으로 게시물을 올릴게요")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            ExportUploadAccountRow(accountLabel: accountLabel, profile: profile)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 363)
        .frame(maxWidth: .infinity)
    }
}

private struct ExportUploadAccountRow<Profile: View>: View {
    let accountLabel: String
    @ViewBuilder let profile: () -> Profile

    var body: some View {
        HStack(spacing: 11) {
            profile()
            Text(accountLabel)
                .font(.title3.weight(.medium))
                .lineLimit(1)
        }
    }
}
