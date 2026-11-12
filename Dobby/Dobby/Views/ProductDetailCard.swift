import SwiftUI

enum ProductDetailCardStyle {
    case standard
    case completion

    var allowsPhotoExpansion: Bool { self == .standard }
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
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .foregroundStyle(Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255))
    }
}

private struct ProductDetailSections: View {
    let garment: Garment
    let measurementAccessibilityPrefix: String
    let photoPresentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style == .completion ? 0 : 18) {
            if style == .completion {
                productName
                sectionDivider
            }
            ProductDetailPhotoSection(garment: garment, presentation: photoPresentation, style: style)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.photos")
            sectionDivider
            if style == .standard {
                productName
                sectionDivider
            }
            ProductDetailField(title: "설명", text: garment.detail, style: style)
            sectionDivider
            ProductDetailField(title: "가격", text: garment.price.map {
                $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + (style == .completion ? "" : " 원")
            } ?? "", style: style)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product-detail.price")
            if !garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sectionDivider
                ProductDetailField(title: "브랜드", text: garment.brand, style: style)
            }
            sectionDivider
            ProductDetailMeasurements(garment: garment, accessibilityPrefix: measurementAccessibilityPrefix,
                                      style: style)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.measurements")
        }
        .frame(minHeight: style == .completion ? 832 : nil, alignment: .leading)
    }

    @ViewBuilder
    private var sectionDivider: some View {
        if style == .completion {
            Spacer(minLength: 16)
            Divider().overlay(Color("BrandNeutral100"))
            Spacer(minLength: 16)
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

    var body: some View {
        ProductFieldTitle(title: title)
            .tracking(-0.43)
            .frame(minHeight: 22, alignment: .leading)
    }
}

private struct ProductDetailField: View {
    let title: String
    let text: String
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: title)
            Text(text)
                .font(style == .completion
                    ? .custom("Pretendard-Regular", size: 15, relativeTo: .subheadline)
                    : .system(size: 14))
                .tracking(-0.23)
                .lineSpacing(3)
                .frame(minHeight: 20, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProductDetailPhotoSection: View {
    let garment: Garment
    let presentation: ProductDetailPhotoPresentation
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: "제품 사진")
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
            ForEach(garment.productPhotos) { photo in
                ProductDetailPhoto(photo: photo, presentation: presentation,
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
            ProductPhotoGalleryView(photos: garment.productPhotos, initialPhotoID: photo.id)
                .presentationBackground(.clear)
        }
    }
}

private struct ProductDetailPhoto: View {
    let photo: GarmentPhoto
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
            } else {
                photograph
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("제품 사진")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductDetailSectionTitle(title: "실측 사이즈")
            if garment.visibleMeasurements.contains(where: {
                $0.sourceStatusRaw == MeasurementStatus.uncertain.rawValue && !$0.isEdited
            }) {
                Text("불확실한 자동 측정값이 포함되어 있어요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ProductDetailMeasurementScroll(values: ProductInformationStyle.measurements(for: garment),
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
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width, CGFloat(values.count) * 64)
                }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(
                style == .completion ? Color("BrandNeutral100") : ProductInformationStyle.field, lineWidth: 1.5)
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
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(accessibilityPrefix).\(value.key)")
            }
        }
        .background(style == .completion ? Color("BrandNeutral100") : ProductInformationStyle.field)
    }
}

private struct ProductDetailMeasurementColumn: View {
    let value: MeasuredValue
    let style: ProductDetailCardStyle

    var body: some View {
        VStack(spacing: 1) {
            Text(ProductInformationStyle.measurementTitle(for: value))
                .font(style == .completion
                    ? .custom("Pretendard-SemiBold", size: 17, relativeTo: .headline)
                    : .headline)
                .tracking(-0.43)
                .foregroundStyle(Color(red: 83 / 255, green: 79 / 255, blue: 73 / 255))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(style == .completion ? Color("BrandNeutral100") : ProductInformationStyle.field)
            Text(MeasurementDisplayText.centimeters(value.valueCm) + "cm")
                .font(style == .completion
                    ? .custom("Pretendard-Regular", size: 15, relativeTo: .subheadline)
                    : .subheadline)
                .tracking(-0.23)
                .foregroundStyle(.black)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(.white)
        }
    }
}
