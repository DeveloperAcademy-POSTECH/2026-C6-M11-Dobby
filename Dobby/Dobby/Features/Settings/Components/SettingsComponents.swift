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
                .lineLimit(1)

            if let subtitle {
                Text(subtitle)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(SettingsStyle.secondaryText)
                    .frame(height: 16, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

struct SettingsSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(SettingsStyle.primaryText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color("HomeAccent") : SettingsStyle.separator)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(SettingsStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color("HomeAccent") : SettingsStyle.separator, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        HStack(spacing: 27) {
            ConnectedAccountIdentity(imageName: imageName, title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            AccountConnectionButton(state: actionState, isWorking: isWorking, action: action)
        }
    }
}

struct ConnectedAccountIdentity: View {
    let imageName: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 15))

            SettingsTextGroup(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccountConnectionButton: View {
    let state: AccountConnectionState
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(state.title)
                    .font(SettingsTypography.labelSmall)
                    .tracking(SettingsTypography.labelSmallTracking)
                    .foregroundStyle(state.foregroundStyle)
            }
        }
        .frame(minWidth: 66, minHeight: 34)
        .background(SettingsStyle.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(SettingsStyle.separator, lineWidth: 1)
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }
}
