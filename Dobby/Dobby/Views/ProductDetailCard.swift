import SwiftUI
import UIKit

enum ProductDetailCardStyle {
    case standard
    case completion
    case library

    var allowsPhotoExpansion: Bool { self != .completion }
    var usesSpacedSections: Bool { self != .standard }
    var usesMeasurementTokens: Bool { self != .standard }
}

enum ProductDetailPhotoPresentation {
    case standard
    case compact

    var size: CGSize {
        switch self {
        case .standard: CGSize(width: 152, height: 212)
        case .compact: CGSize(width: 77, height: 108)
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .standard: 16
        case .compact: 8
        }
    }

    var showsExpansionIcon: Bool {
        switch self {
        case .standard: true
        case .compact: false
        }
    }
}

struct ProductDetailCard: View {
    let garment: Garment
    var measurementAccessibilityPrefix = "product-detail.measurement"
    var photoPresentation: ProductDetailPhotoPresentation = .standard
    var style: ProductDetailCardStyle = .standard

    var body: some View {
        ProductDetailSections(garment: garment, measurementAccessibilityPrefix: measurementAccessibilityPrefix,
                              photoPresentation: photoPresentation, style: style)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: style.usesSpacedSections ? .circular : .continuous))
            .foregroundStyle(Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255))
            .accessibilityElement(children: .contain)
    }
}

private struct ProductDetailSections: View {
    let garment: Garment
    let measurementAccessibilityPrefix: String
    let photoPresentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.usesSpacedSections ? 0 : 18) {
            if style == .completion {
                productName
                sectionDivider
            }
            ProductDetailPhotoSection(garment: garment, presentation: photoPresentation, style: style)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.photos")
            sectionDivider
            if style != .completion {
                productName
                sectionDivider
            }
            ProductDetailField(title: "설명", text: garment.detail, style: style, trailingInset: style == .library ? 6 : 0)
            sectionDivider
            ProductDetailField(title: "가격", text: garment.price.map {
                $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + (style == .standard ? " 원" : "")
            } ?? "", style: style, suffix: style == .library && garment.price != nil ? "원" : nil)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product-detail.price")
            if style == .library || !garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sectionDivider
                ProductDetailField(title: "브랜드",
                    text: garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Brand" : garment.brand,
                    style: style,
                    textColor: style == .library && garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color("BrandNeutral500") : nil)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("product-detail.brand")
            }
            sectionDivider
            ProductDetailMeasurements(garment: garment, accessibilityPrefix: measurementAccessibilityPrefix,
                                      style: style)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.measurements")
        }
        .frame(minHeight: style.usesSpacedSections ? 832 : nil, alignment: .leading)
    }

    @ViewBuilder
    private var sectionDivider: some View {
        if style.usesSpacedSections {
            Spacer(minLength: style == .library ? 24 : 16)
            Color("BrandNeutral100").frame(height: 1)
            Spacer(minLength: style == .library ? 24 : 16)
        } else {
            Divider()
        }
    }

    private var productName: some View {
        ProductDetailField(title: "제품명", text: garment.name, style: style)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product-detail.name")
    }
}

private struct ProductDetailSectionTitle: View {
    let title: String
    var libraryFont: Font? = nil

    var body: some View {
        Group {
            if let libraryFont {
                Text(title).font(libraryFont)
            } else {
                ProductFieldTitle(title: title)
            }
        }
            .tracking(-0.43)
            .frame(minHeight: 22, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct ProductDetailField: View {
    let title: String
    let text: String
    let style: ProductDetailCardStyle
    var trailingInset: CGFloat = 0
    var suffix: String? = nil
    var textColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: title, libraryFont: style == .library ? LibraryDetailTypography.heading : nil)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                fieldText(text)
                if let suffix { fieldText(suffix) }
            }
            .padding(.trailing, trailingInset)
            .frame(maxWidth: style == .library ? .infinity : nil, alignment: .leading)
        }
        .frame(maxWidth: style == .library ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "입력하지 않음" : text + (suffix.map { " \($0)" } ?? ""))
    }

    private var usesCompletionBody: Bool { style == .completion }

    private var textFont: Font {
        if style == .library { return LibraryDetailTypography.body }
        if style == .completion {
            return .custom("Pretendard-Regular", size: usesCompletionBody ? 17 : 15,
                           relativeTo: usesCompletionBody ? .body : .subheadline)
        }
        return .system(size: 14)
    }

    private var textLineSpacing: CGFloat {
        if style == .library { return max(0, 20 - UIFont.systemFont(ofSize: 14).lineHeight) }
        if style == .completion {
            let size: CGFloat = usesCompletionBody ? 17 : 15
            let height: CGFloat = usesCompletionBody ? 22 : 20
            return max(0, height - (UIFont(name: "Pretendard-Regular", size: size)?.lineHeight ?? height))
        }
        return 3
    }

    private func fieldText(_ value: String) -> some View {
        Text(value)
            .foregroundColor(textColor ?? (style == .completion && title == "가격" ? .black : nil))
            .font(textFont)
            .tracking(usesCompletionBody ? -0.43 : -0.23)
            .lineSpacing(textLineSpacing)
            .multilineTextAlignment(.leading)
            .frame(minHeight: usesCompletionBody ? 22 : 20, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

}

private struct ProductDetailPhotoSection: View {
    let garment: Garment
    let presentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: "제품 사진",
                libraryFont: style == .library ? LibraryDetailTypography.photoAndMeasurementHeading : nil)
            ProductDetailPhotos(garment: garment, presentation: presentation, style: style)
                .padding(.trailing, -16)
        }
    }
}

private struct ProductDetailPhotos: View {
    let garment: Garment
    let presentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductDetailPhotoRow(garment: garment, presentation: presentation, style: style)
                .padding(.trailing, 16)
        }
    }
}

private struct ProductDetailPhotoRow: View {
    let garment: Garment
    let presentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle
    @State private var expandedPhoto: GarmentPhoto?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(garment.productPhotos.enumerated()), id: \.element.id) { index, photo in
                ProductDetailPhoto(photo: photo, index: index, count: garment.productPhotos.count,
                    presentation: presentation,
                    allowsExpansion: style.allowsPhotoExpansion,
                    showsExpansionIcon: style.allowsPhotoExpansion && presentation.showsExpansionIcon
                        && photo.id == garment.productPhotos.first?.id,
                    onExpand: {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { expandedPhoto = photo }
                    })
            }
        }
        .fullScreenCover(item: $expandedPhoto) { photo in
            ProductPhotoGalleryView(photos: garment.productPhotos, initialPhotoID: photo.id,
                                    style: style == .library ? .library : .standard)
                .presentationBackground(.clear)
        }
    }
}

private struct ProductDetailPhoto: View {
    let photo: GarmentPhoto
    let index: Int
    let count: Int
    let presentation: ProductDetailPhotoPresentation
    let allowsExpansion: Bool
    let showsExpansionIcon: Bool
    let onExpand: () -> Void

    var body: some View {
        Group {
            if allowsExpansion {
                Button(action: onExpand) { photograph }
                    .buttonStyle(.plain)
                    .accessibilityLabel("제품 사진 확대")
                    .accessibilityValue("\(count)장 중 \(index + 1)번째 사진")
                    .accessibilityHint("사진 전체 화면을 엽니다")
            } else {
                photograph
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("제품 사진 \(index + 1), 총 \(count)장")
                    .accessibilityAddTraits(.isImage)
            }
        }
        .accessibilityIdentifier("product-detail.photo.\(photo.id)")
    }

    private var photograph: some View {
        StoredProductPhotoView(photo: photo, maximumPixelSize: 640)
            .frame(width: presentation.size.width, height: presentation.size.height)
            .clipShape(RoundedRectangle(cornerRadius: presentation.cornerRadius))
            .overlay(alignment: .bottomTrailing) {
                if showsExpansionIcon {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.2), in: Circle()).padding(10)
                }
            }
    }
}

private struct ProductDetailMeasurements: View {
    let garment: Garment
    let accessibilityPrefix: String
    let style: ProductDetailCardStyle

    private var displayedMeasurements: [MeasuredValue] {
        let values = ProductInformationStyle.measurements(for: garment)
        guard style == .completion, garment.group == .top else { return values }
        let keys = ["shoulderWidth", "chestWidth", "totalLength", "sleeveLengthLeft", "sleeveLengthRight"]
        return values.enumerated().sorted { left, right in
            let leftOrder = keys.firstIndex(of: left.element.key) ?? keys.count
            let rightOrder = keys.firstIndex(of: right.element.key) ?? keys.count
            return leftOrder == rightOrder ? left.offset < right.offset : leftOrder < rightOrder
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: "실측 사이즈", libraryFont: style == .library ? LibraryDetailTypography.heading : nil)
            ProductDetailMeasurementScroll(values: displayedMeasurements,
                                           accessibilityPrefix: accessibilityPrefix, style: style)
        }
    }
}

private struct ProductDetailMeasurementScroll: View {
    let values: [MeasuredValue]
    let accessibilityPrefix: String
    let style: ProductDetailCardStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductDetailMeasurementRow(values: values, accessibilityPrefix: accessibilityPrefix, style: style)
                .padding(style == .library ? 1.5 : 0)
                .containerRelativeFrame(.horizontal) { width, _ in
                    if style == .library {
                        return values.count <= 5 ? width : max(width, CGFloat(values.count) * 85 - 1)
                    }
                    return max(width, CGFloat(values.count) * 64)
                }
        }
        .scrollDisabled(style == .library && values.count <= 5)
        .background(style == .library ? Color("BrandNeutral50") : .white)
        .clipShape(RoundedRectangle(cornerRadius: style == .completion ? 16 : 14,
                                    style: style.usesMeasurementTokens ? .circular : .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: style == .completion ? 16 : 14,
                                    style: style.usesMeasurementTokens ? .circular : .continuous).strokeBorder(
                style.usesMeasurementTokens ? Color("BrandNeutral50") : ProductInformationStyle.field, lineWidth: 1.5)
        }
    }
}

private struct ProductDetailMeasurementRow: View {
    let values: [MeasuredValue]
    let accessibilityPrefix: String
    let style: ProductDetailCardStyle

    var body: some View {
        HStack(spacing: 1) {
            ForEach(values) { value in
                ProductDetailMeasurementColumn(value: value, style: style)
                    .frame(minWidth: style == .library && values.count > 5 ? 84 : 0)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(accessibilityPrefix).\(value.key)")
            }
        }
        .background(style.usesMeasurementTokens ? Color("BrandNeutral50") : ProductInformationStyle.field)
    }
}

private struct ProductDetailMeasurementColumn: View {
    let value: MeasuredValue
    let style: ProductDetailCardStyle

    private var usesBodyValue: Bool { style == .completion && value.key == "totalLength" }

    private var valueFont: Font {
        if usesBodyValue {
            return .custom("Pretendard-Regular", size: 17, relativeTo: .body)
        }
        return style.usesMeasurementTokens ? LibraryDetailTypography.measurementValue : .subheadline
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(style.usesMeasurementTokens && value.key == "totalLength" ? "총장" : ProductInformationStyle.measurementTitle(for: value))
                .font(style.usesMeasurementTokens
                    ? LibraryDetailTypography.photoAndMeasurementHeading
                    : .headline)
                .tracking(-0.43)
                .foregroundStyle(Color("BrandNeutral800"))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(style.usesMeasurementTokens ? Color("BrandNeutral50") : ProductInformationStyle.field)
            Text(MeasurementDisplayText.centimeters(value.valueCm) + "cm")
                .font(valueFont)
                .tracking(usesBodyValue ? -0.43 : -0.23)
                .foregroundStyle(style == .library ? Color("BrandNeutralBlack") : .black)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(Color("BrandNeutralWhite"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .library && value.key == "totalLength" ? "총장" : ProductInformationStyle.measurementTitle(for: value))
        .accessibilityValue(value.valueCm.isFinite && value.valueCm > 0
            ? MeasurementDisplayText.centimeters(value.valueCm) + "cm" : "측정값 없음")
    }
}
