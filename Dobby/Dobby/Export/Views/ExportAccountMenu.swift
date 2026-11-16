import SwiftUI

struct ExportAccountMenu: View {
    let accessibilityLabel: String
    let onReconnect: () -> Void
    let onDisconnect: () -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Color(.exportCloseIcon))
        }
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented) {
            VStack(alignment: .center, spacing: 0) {
                ExportAccountMenuButton(
                    title: "다시 연결하기",
                    systemImage: "arrow.clockwise",
                    action: performReconnect
                )
                ExportAccountMenuButton(
                    title: "연결 해제하기",
                    systemImage: "personalhotspot.slash",
                    tint: Color(.accentsRed),
                    action: performDisconnect
                )
            }
            .padding(.vertical, 10)
            .frame(width: 238, alignment: .top)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func performReconnect() {
        isPresented = false
        onReconnect()
    }

    private func performDisconnect() {
        isPresented = false
        onDisconnect()
    }
}

private struct ExportAccountMenuButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.custom("Pretendard", fixedSize: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .frame(width: 206, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .accessibilityLabel(title)
    }
}

#Preview("계정 메뉴 · 버튼을 눌러 열기") {
    NavigationStack {
        Color(.brandNeutralWhite)
            .navigationTitle("인스타그램에 업로드하기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ExportAccountMenu(
                        accessibilityLabel: "Instagram 계정 메뉴",
                        onReconnect: {},
                        onDisconnect: {}
                    )
                    .buttonBorderShape(.capsule)
                }
            }
    }
}

#Preview("계정 메뉴 · 항목", traits: .sizeThatFitsLayout) {
    VStack(spacing: 0) {
        ExportAccountMenuButton(
            title: "다시 연결하기",
            systemImage: "arrow.clockwise",
            action: {}
        )

        ExportAccountMenuButton(
            title: "연결 해제하기",
            systemImage: "personalhotspot.slash",
            tint: Color(.accentsRed),
            action: {}
        )
    }
    .padding(.vertical, 10)
    .frame(width: 238)
    .background(Color(.brandNeutralWhite))
}
