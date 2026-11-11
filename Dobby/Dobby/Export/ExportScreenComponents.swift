import SwiftUI
import UIKit

enum ExportScreenStyle {
    static let horizontalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 20
    static let cardCornerRadius: CGFloat = 22
    static let fieldCornerRadius: CGFloat = 14

    static let background = Color(.systemGroupedBackground)
    static let card = Color(.systemBackground)
    static let field = Color("BrandNeutral100")
    static let accent = Color("BrandMain500")
    static let accentSoft = Color("BrandMain300")
    static let label = Color("BrandNeutral800")
}

struct ExportScreenContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ExportScreenStyle.sectionSpacing) {
                content
            }
            .padding(.horizontal, ExportScreenStyle.horizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 116)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ExportScreenStyle.background.ignoresSafeArea())
    }
}

struct ExportServiceHeader: View {
    let channel: ExportChannel
    let title: String
    let description: String
    var status: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(channel.imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                    if let status {
                        ExportStatusBadge(title: status)
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(ExportScreenStyle.card, in: RoundedRectangle(cornerRadius: ExportScreenStyle.cardCornerRadius))
    }
}

struct ExportSectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ExportScreenStyle.card, in: RoundedRectangle(cornerRadius: ExportScreenStyle.cardCornerRadius))
    }
}

struct ExportStatusBadge: View {
    let title: String
    var color: Color = ExportScreenStyle.accent

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct ExportInfoBanner: View {
    let text: String
    var systemImage = "info.circle.fill"
    var tint: Color = ExportScreenStyle.accent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
    }
}

struct ExportProductSummary: View {
    let product: ExportProduct
    var photoCount: Int? = nil

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let data = product.thumbnailData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "tshirt")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 76)
            .background(ExportScreenStyle.field)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Text(product.name.isEmpty ? "이름 없는 상품" : product.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Label("사진 \(photoCount ?? product.exportPhotos.count)장", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExportField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ExportScreenStyle.label)
            content
        }
    }
}

struct ExportTextFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
    }
}

extension View {
    func exportTextFieldStyle() -> some View {
        modifier(ExportTextFieldBackground())
    }
}

struct ExportNavigationButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(Color(.exportCloseIcon))
        }
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }
}

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
            VStack(spacing: 0) {
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
            .padding(12)
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
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 28, alignment: .center)

                Text(title)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(width: 206, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }
}

struct ExportBottomAction: View {
    let title: String
    var isWorking = false
    var isComplete = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        ChakPrimaryButton(
            title: title,
            isLoading: isWorking,
            showsCompletion: isComplete
        ) {
            action()
        }
        .disabled(!isEnabled || isWorking)
    }
}

struct ExportBottomActionBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, ExportScreenStyle.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
    }
}

struct ExportLoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
            HStack(spacing: 12) {
                ProgressView()
                    .tint(ExportScreenStyle.accent)
                Text(message)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(true)
        .accessibilityElement(children: .combine)
    }
}
