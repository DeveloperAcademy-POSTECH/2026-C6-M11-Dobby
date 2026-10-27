import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(SettingsTypography.sectionTitle)
                .tracking(SettingsTypography.sectionTitleTracking)
                .foregroundStyle(SettingsStyle.primaryText)

            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsStyle.surface)
    }
}

struct SettingsTextGroup: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(SettingsTypography.labelMedium)
                .tracking(SettingsTypography.labelMediumTracking)
                .foregroundStyle(SettingsStyle.primaryText)

            if let subtitle {
                Text(subtitle)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(SettingsStyle.secondaryText)
            }
        }
    }
}

struct SettingsNavigationRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsTextGroup(title: title, subtitle: subtitle)

            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsStyle.primaryText)
        }
        .contentShape(Rectangle())
    }
}

enum AccountConnectionState {
    case connect
    case disconnect

    var title: String {
        switch self {
        case .connect: "연결하기"
        case .disconnect: "연결 해제"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .connect: SettingsStyle.buttonText
        case .disconnect: SettingsStyle.destructive
        }
    }
}

struct ConnectedAccountRow: View {
    let title: String
    let subtitle: String?
    let imageName: String
    let actionState: AccountConnectionState
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)

            SettingsTextGroup(title: title, subtitle: subtitle)

            Spacer()

            AccountConnectionButton(state: actionState, isWorking: isWorking, action: action)
        }
        .padding(.vertical, 16)
    }
}

struct AccountConnectionButton: View {
    let state: AccountConnectionState
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isWorking {
                ProgressView()
            } else {
                Button(state.title, action: action)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(state.foregroundStyle)
            }
        }
        .frame(width: 68)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
