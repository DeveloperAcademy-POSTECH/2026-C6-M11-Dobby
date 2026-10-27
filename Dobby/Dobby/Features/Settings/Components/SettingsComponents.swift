import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(title: String, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .font(SettingsTypography.sectionTitle)
                .tracking(SettingsTypography.sectionTitleTracking)
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(height: 29, alignment: .leading)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsTextGroup: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(SettingsTypography.labelMedium)
                .tracking(SettingsTypography.labelMediumTracking)
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(height: 20, alignment: .leading)

            if let subtitle {
                Text(subtitle)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(SettingsStyle.secondaryText)
                    .frame(height: 16, alignment: .leading)
            }
        }
    }
}

struct SettingsNavigationRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 27) {
            SettingsTextGroup(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SettingsStyle.primaryText)
                .frame(width: 16, height: 20)
        }
        .contentShape(Rectangle())
    }
}

struct SettingsHeader: View {
    var body: some View {
        Text("설정")
            .font(SettingsTypography.screenTitle)
            .tracking(SettingsTypography.screenTitleTracking)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 33, alignment: .leading)
    }
}

struct SettingsSectionSeparator: View {
    var body: some View {
        SettingsStyle.sectionSeparator
            .frame(height: 6)
            .padding(.horizontal, -20)
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
