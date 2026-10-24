import SwiftUI
import UIKit

/// Figma Frame 217. Product content comes from the saved garment.
struct ProductLibraryCard: View {
    let garment: Garment
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var brandLineHeight: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var priceLineHeight: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(garment.name)
                    .modifier(LibraryCardTextStyle(size: 14, lineHeight: 16, relativeTo: .subheadline))
                    .foregroundStyle(LibraryCardStyle.title)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: titleLineHeight * 3, alignment: .topLeading)

                Text(garment.brand)
                    .modifier(LibraryCardTextStyle(size: 12, lineHeight: 14, relativeTo: .caption))
                    .foregroundStyle(LibraryCardStyle.brand)
                    .lineLimit(1)
                    .frame(height: brandLineHeight, alignment: .topLeading)

                Text(garment.price.map { $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) } ?? "")
                    .modifier(LibraryCardTextStyle(size: 14, lineHeight: 16, relativeTo: .subheadline))
                    .foregroundStyle(LibraryCardStyle.price)
                    .lineLimit(1)
                    .frame(height: priceLineHeight, alignment: .topLeading)

                platformBadges
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    private var thumbnail: some View {
        GeometryReader { geometry in
            Group {
                if let photo = garment.thumbnail {
                    StoredProductPhotoView(photo: photo, maximumPixelSize: 700)
                } else {
                    Rectangle()
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(123.0 / 164.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }

    private var platformBadges: some View {
        let channels = garment.selectedExportChannels
        return HStack(spacing: -4) {
            ForEach(Array(channels.enumerated()), id: \.element) { index, channel in
                Image(channel.libraryBadgeAssetName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                    .zIndex(Double(channels.count - index))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("선택한 내보내기 플랫폼: " + channels.map(\.title).joined(separator: ", "))
        .accessibilityIdentifier("library.platforms.\(garment.id.uuidString)")
        .accessibilityHidden(channels.isEmpty)
    }

    private var cardAccessibilityLabel: String {
        var values = [garment.name.isEmpty ? "저장된 상품" : garment.name, garment.brand]
        if let price = garment.price {
            values.append(price.formatted(.number.locale(Locale(identifier: "ko_KR"))))
        }
        if !garment.selectedExportChannels.isEmpty {
            values.append("선택한 내보내기 플랫폼: " + garment.selectedExportChannels.map(\.title).joined(separator: ", "))
        }
        return values.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

private extension ExportChannel {
    var libraryBadgeAssetName: String {
        switch self {
        case .instagram: return "LibraryInstagramBadge"
        case .naverStore: return imageName
        case .cafe24: return "LibraryCafe24Badge"
        case .fruitsFamily: return "LibraryFruitsFamilyBadge"
        }
    }
}

private enum LibraryCardStyle {
    static let fontName = "Pretendard-Medium"
    static let title = LibraryStyle.primary
    static let brand = Color(red: 111.0 / 255, green: 106.0 / 255, blue: 99.0 / 255)
    static let price = Color(red: 66.0 / 255, green: 62.0 / 255, blue: 58.0 / 255)
}

/// Uses Figma's line height while allowing the type to scale with accessibility settings.
private struct LibraryCardTextStyle: ViewModifier {
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var lineHeight: CGFloat

    init(size: CGFloat, lineHeight: CGFloat, relativeTo textStyle: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        _lineHeight = ScaledMetric(wrappedValue: lineHeight, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        let font = UIFont(name: LibraryCardStyle.fontName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .medium)
        let lineHeightAdjustment = lineHeight - font.lineHeight

        content
            .font(.custom(LibraryCardStyle.fontName, fixedSize: size))
            .tracking(-size * 0.01)
            .lineSpacing(lineHeightAdjustment)
            .padding(.vertical, lineHeightAdjustment / 2)
    }
}

#if DEBUG
#Preview("Frame 217 · 175pt") {
    ProductLibraryCard(garment: LibraryPreviewData.garments[0])
        .frame(width: 175)
        .padding(20)
        .background(LibraryStyle.background)
}

#Preview("값 유무와 관계없이 같은 카드 크기") {
    let empty = Garment(category: "Jacket", group: .top)
    return HStack(alignment: .top, spacing: 12) {
        ProductLibraryCard(garment: LibraryPreviewData.garments[0])
            .frame(width: 175)
        ProductLibraryCard(garment: empty)
            .frame(width: 175)
    }
    .padding(20)
    .background(LibraryStyle.background)
}
#endif
