import SwiftUI

struct ChakButtonAction {
    let title: String
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
}

struct ChakHorizontalActionButtons: View {
    let secondary: ChakButtonAction
    let primary: ChakButtonAction

    var body: some View {
        HStack(spacing: 8) {
            ChakActionButton(
                configuration: secondary,
                fontName: "Pretendard-Medium",
                foregroundColor: Color(.brandMain500),
                backgroundColor: Color(.brandMain100),
                horizontalPadding: 0,
                height: 56
            )
            ChakActionButton(
                configuration: primary,
                fontName: "Pretendard-Medium",
                foregroundColor: Color(.brandNeutralWhite),
                backgroundColor: Color(.brandMain500),
                horizontalPadding: 0,
                height: 56
            )
        }
    }
}

struct ChakVerticalActionButtons: View {
    let secondary: ChakButtonAction
    let primary: ChakButtonAction

    var body: some View {
        VStack(spacing: 8) {
            ChakActionButton(
                configuration: secondary,
                fontName: "Pretendard-SemiBold",
                foregroundColor: Color(.brandMain500),
                backgroundColor: Color(.brandNeutral100),
                horizontalPadding: 28,
                height: 58
            )
            ChakActionButton(
                configuration: primary,
                fontName: "Pretendard-SemiBold",
                foregroundColor: Color(.brandNeutralWhite),
                backgroundColor: Color(.brandMain500),
                horizontalPadding: 28,
                height: 58
            )
        }
    }
}

private struct ChakActionButton: View {
    let configuration: ChakButtonAction
    let fontName: String
    let foregroundColor: Color
    let backgroundColor: Color
    let horizontalPadding: CGFloat
    let height: CGFloat

    var body: some View {
        Button(action: configuration.action) {
            Text(configuration.title)
                .font(.custom(fontName, fixedSize: 16))
                .multilineTextAlignment(.center)
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: Capsule())
        .accessibilityIdentifier(configuration.accessibilityIdentifier ?? "")
    }
}

#Preview("가로 액션 버튼") {
    ChakHorizontalActionButtons(
        secondary: .init(title: "취소하기", action: {}),
        primary: .init(title: "다시 업로드하기", action: {})
    )
    .padding(17)
    .frame(width: 360)
    .background(Color(.brandNeutralWhite))
}

#Preview("세로 액션 버튼") {
    ChakVerticalActionButtons(
        secondary: .init(title: "보관함으로 가기", action: {}),
        primary: .init(title: "인스타그램 열기", action: {})
    )
    .padding(.horizontal, 34)
    .padding(.vertical, 16)
    .frame(width: 402)
    .background(Color(.brandNeutral50))
}
