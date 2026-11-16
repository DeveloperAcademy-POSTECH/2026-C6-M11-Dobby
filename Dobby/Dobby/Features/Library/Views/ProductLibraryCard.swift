import SwiftUI
import UIKit

/// Figma's library card. Product content comes from the saved garment.
struct ProductLibraryCard: View {
    let garment: Garment
    let showsDraftPlaceholders: Bool
    @ScaledMetric(relativeTo: .subheadline) private var titleLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .callout) private var brandLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .subheadline) private var priceLineHeight: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var registrationLineHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var informationHeight: CGFloat = 167
    init(garment: Garment, showsDraftPlaceholders: Bool = false) {
        self.garment = garment
        self.showsDraftPlaceholders = showsDraftPlaceholders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayBrand)
                        .modifier(LibraryCardTextStyle(
                            size: garment.brand.isBlank ? 17 : 16,
                            lineHeight: garment.brand.isBlank ? 22 : 20,
                            relativeTo: .callout,
                            fontName: garment.brand.isBlank ? "Pretendard-SemiBold" : "Pretendard-Medium"
                        ))
                        .foregroundStyle(garment.brand.isBlank ? Color("BrandNeutral500") : LibraryCardStyle.brand)
                        .lineLimit(showsDraftPlaceholders ? 2 : 1)
                        .frame(minHeight: brandLineHeight, alignment: .topLeading)

                    LibraryCardTitle(text: displayName)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(minHeight: titleLineHeight, alignment: .topLeading)

                    Text(displayPrice)
                        .modifier(LibraryCardTextStyle(size: 14, lineHeight: 16, relativeTo: .subheadline))
                        .foregroundStyle(LibraryCardStyle.price)
                        .lineLimit(1)
                        .frame(height: priceLineHeight, alignment: .topLeading)

                    if !showsDraftPlaceholders { platformBadges }
                }

                if let registrationDateText {
                    Spacer(minLength: 8)
                    Text(registrationDateText)
                        .modifier(LibraryCardTextStyle(size: 13, lineHeight: 18, relativeTo: .footnote, fontName: "Pretendard-Regular"))
                        .foregroundStyle(Color("BrandNeutral400"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(height: registrationLineHeight, alignment: .topLeading)
                        .accessibilityIdentifier("library.registration-date.\(garment.id.uuidString)")
                }
            }
            .padding(10)
            .frame(height: informationHeight, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 16))
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
        .aspectRatio(175.0 / 233.0, contentMode: .fit)
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
        var values = [garment.name.isBlank ? "이름 없는 상품" : garment.name,
                      garment.brand.isBlank ? "브랜드 없음" : "브랜드 \(garment.brand)"]
        if let price = garment.price {
            values.append("가격 \(price.formatted(.number.locale(Locale(identifier: "ko_KR"))))원")
        } else {
            values.append("가격 미입력")
        }
        values.append("사진 \(garment.productPhotos.count)장")
        if showsDraftPlaceholders, let draft = garment.creationDraft {
            values.append("임시저장, 현재 \(draft.step.title)")
        }
        if !garment.selectedExportChannels.isEmpty {
            values.append("선택한 내보내기 플랫폼: " + garment.selectedExportChannels.map(\.title).joined(separator: ", "))
        }
        if let registrationDateText {
            values.append((showsDraftPlaceholders ? "임시저장일: " : "최초 등록일: ") + registrationDateText)
        }
        return values.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var registrationDateText: String? {
        let date = showsDraftPlaceholders ? garment.creationDraft?.savedAt : garment.registeredAt
        return date.map { LibraryCardStyle.registrationDateFormatter.string(from: $0) }
    }

    private var displayBrand: String {
        garment.brand.isBlank ? "No Brand" : garment.brand
    }

    private var displayName: String {
        garment.name.isBlank && showsDraftPlaceholders ? "제목 없음" : garment.name
    }

    private var displayPrice: String {
        if let price = garment.price {
            return price.formatted(.number.locale(Locale(identifier: "ko_KR")))
        }
        return showsDraftPlaceholders ? "Price" : ""
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension ExportChannel {
    var libraryBadgeAssetName: String {
        switch self {
        case .instagram: return "LibraryInstagramBadge"
        case .naverStore: return ""
        case .cafe24: return "LibraryCafe24Badge"
        case .fruitsFamily: return "LibraryFruitsFamilyBadge"
        }
    }
}

private enum LibraryCardStyle {
    static let registrationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy.M.d"
        return formatter
    }()
    static let fontName = "Pretendard-Medium"
    static let title = UIColor(Color("BrandNeutralBlack"))
    static let brand = Color("BrandNeutralBlack")
    static let price = Color("BrandNeutral900")
}

/// Disables the label's Korean orphan prevention so wrapping uses the full card text width.
private struct LibraryCardTitle: UIViewRepresentable {
    let text: String
    @ScaledMetric(relativeTo: .subheadline) private var fontSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight: CGFloat = 20

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.lineBreakStrategy = []
        label.adjustsFontForContentSizeCategory = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let font = UIFont(name: "Pretendard-Regular", size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.lineBreakStrategy = []

        label.font = font
        label.textColor = LibraryCardStyle.title
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: LibraryCardStyle.title,
            .kern: -0.23 * fontSize / 15,
            .paragraphStyle: paragraph
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        guard width > 0 else { return CGSize(width: max(0, width), height: lineHeight) }
        label.preferredMaxLayoutWidth = width
        guard !text.isEmpty else { return CGSize(width: width, height: lineHeight) }

        let measuredHeight = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let singleLineHeight = label.textRect(
            forBounds: CGRect(x: 0, y: 0, width: width, height: lineHeight * 2),
            limitedToNumberOfLines: 1
        ).height
        // UILabel rounds glyph bounds, so dividing its height by the design line height
        // can incorrectly count one line as two. Compare against the same label's one-line bounds.
        let numberOfLines: CGFloat = measuredHeight > singleLineHeight + 0.5 ? 2 : 1
        return CGSize(width: width, height: lineHeight * numberOfLines)
    }
}

/// Uses Figma's line height while allowing the type to scale with accessibility settings.
private struct LibraryCardTextStyle: ViewModifier {
    let fontName: String
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var lineHeight: CGFloat

    init(size: CGFloat, lineHeight: CGFloat, relativeTo textStyle: Font.TextStyle, fontName: String = LibraryCardStyle.fontName) {
        self.fontName = fontName
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        _lineHeight = ScaledMetric(wrappedValue: lineHeight, relativeTo: textStyle)
    }

    func body(content: Content) -> some View {
        let font = UIFont(name: fontName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .medium)
        let lineHeightAdjustment = lineHeight - font.lineHeight

        content
            .font(.custom(fontName, fixedSize: size))
            .tracking(-size * 0.01)
            .lineSpacing(lineHeightAdjustment)
            .padding(.vertical, lineHeightAdjustment / 2)
    }
}

#if DEBUG
#Preview("보관함 카드 · 브랜드 우선 · 175pt") {
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

#Preview("임시저장 빈 값 안내") {
    ProductLibraryCard(
        garment: Garment(category: "Jacket", group: .top),
        showsDraftPlaceholders: true
    )
    .frame(width: 175)
    .padding(20)
    .background(LibraryStyle.background)
}

#Preview("상품명 · 한 줄 / 두 줄 / 말줄임 / 빈 값") {
    let names = [
        "팝오버 니트",
        "황계 카모플라주 후드 셔츠 자켓",
        "황계 카모플라주 후드 셔츠 자켓과 길이가 긴 상품명을 두 줄까지만 표시합니다",
        ""
    ]
    return ScrollView {
        LazyVGrid(columns: [GridItem(.fixed(175)), GridItem(.fixed(175))], spacing: 12) {
            ForEach(names, id: \.self) { name in
                ProductLibraryCard(garment: Garment(
                    category: "Jacket", group: .top, name: name, brand: "Bape", price: 155_000
                ))
            }
        }
        .padding(20)
    }
    .background(LibraryStyle.background)
}
#endif
