import SwiftUI

struct PairedActionButtons: View {
    struct Action {
        let title: String
        var accessibilityIdentifier: String? = nil
        let handler: () -> Void
    }

    let secondary: Action
    let primary: Action
    var minimumHeight: CGFloat = 56

    var body: some View {
        HStack(spacing: 8) {
            actionButton(
                secondary,
                foregroundColor: Color(.brandNeutral900),
                backgroundColor: Color(.brandNeutral100)
            )
            actionButton(
                primary,
                foregroundColor: Color(.brandNeutralWhite),
                backgroundColor: Color(.brandMain500)
            )
        }
    }

    @ViewBuilder
    private func actionButton(
        _ action: Action,
        foregroundColor: Color,
        backgroundColor: Color
    ) -> some View {
        if let accessibilityIdentifier = action.accessibilityIdentifier {
            button(
                action,
                foregroundColor: foregroundColor,
                backgroundColor: backgroundColor
            )
            .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            button(
                action,
                foregroundColor: foregroundColor,
                backgroundColor: backgroundColor
            )
        }
    }

    private func button(
        _ action: Action,
        foregroundColor: Color,
        backgroundColor: Color
    ) -> some View {
        Button(action: action.handler) {
            Text(action.title)
                .font(.custom("Pretendard-Medium", fixedSize: 16))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: minimumHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: Capsule())
    }
}
