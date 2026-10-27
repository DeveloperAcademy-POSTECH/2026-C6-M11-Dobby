import SwiftUI

struct ProductDetailCard: View {
    let garment: Garment
    var measurementAccessibilityPrefix = "product-detail.measurement"

    var body: some View {
        ProductDetailSections(garment: garment, measurementAccessibilityPrefix: measurementAccessibilityPrefix)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProductDetailPhotoSection(garment: garment)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.photos")
            Divider()
            ProductDetailField(title: "제품명", text: garment.name)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.name")
            Divider()
            ProductDetailField(title: "설명", text: garment.detail)
            Divider()
            ProductDetailField(title: "가격", text: garment.price.map {
                $0.formatted(.number.locale(Locale(identifier: "ko_KR"))) + " 원"
            } ?? "")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("product-detail.price")
            if !garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                ProductDetailField(title: "브랜드", text: garment.brand)
            }
            Divider()
            ProductDetailMeasurements(garment: garment, accessibilityPrefix: measurementAccessibilityPrefix)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-detail.measurements")
        }
    }
}

private struct ProductDetailField: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: title)
                .tracking(-0.43)
                .frame(minHeight: 22, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .tracking(-0.23)
                .lineSpacing(3)
                .frame(minHeight: 20, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProductDetailPhotoSection: View {
    let garment: Garment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "제품 사진")
                .tracking(-0.43)
                .frame(minHeight: 22, alignment: .leading)
            ProductDetailPhotos(garment: garment)
                .padding(.trailing, -16)
        }
    }
}

private struct ProductDetailPhotos: View {
    let garment: Garment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductDetailPhotoRow(garment: garment)
                .padding(.trailing, 16)
        }
    }
}

private struct ProductDetailPhotoRow: View {
    let garment: Garment

    var body: some View {
        HStack(spacing: 8) {
            ForEach(garment.productPhotos) { photo in
                ProductDetailPhoto(photo: photo, showsExpansionIcon: photo.id == garment.productPhotos.first?.id)
            }
        }
    }
}

private struct ProductDetailPhoto: View {
    let photo: GarmentPhoto
    let showsExpansionIcon: Bool
    @State private var isExpanded = false

    var body: some View {
        Button { isExpanded = true } label: {
            StoredProductPhotoView(photo: photo, maximumPixelSize: 640)
                .frame(width: 152, height: 212)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    if showsExpansionIcon {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12)).foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.2), in: Circle()).padding(10)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("제품 사진 확대")
        .sheet(isPresented: $isExpanded) {
            ProductExpandedPhoto(photo: photo)
        }
    }
}

private struct ProductExpandedPhoto: View {
    let photo: GarmentPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StoredProductPhotoView(photo: photo, maximumPixelSize: 2400, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .navigationTitle("제품 사진")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
    }
}

private struct ProductDetailMeasurements: View {
    let garment: Garment
    let accessibilityPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "실측 사이즈")
                .tracking(-0.43)
                .frame(minHeight: 22, alignment: .leading)
            if garment.visibleMeasurements.contains(where: {
                $0.sourceStatusRaw == MeasurementStatus.uncertain.rawValue && !$0.isEdited
            }) {
                Text("불확실한 자동 측정값이 포함되어 있어요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ProductDetailMeasurementScroll(values: ProductInformationStyle.measurements(for: garment),
                                           accessibilityPrefix: accessibilityPrefix)
        }
    }
}

private struct ProductDetailMeasurementScroll: View {
    let values: [MeasuredValue]
    let accessibilityPrefix: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductDetailMeasurementRow(values: values, accessibilityPrefix: accessibilityPrefix)
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width, CGFloat(values.count) * 64)
                }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(ProductInformationStyle.field, lineWidth: 1.5)
        }
    }
}

private struct ProductDetailMeasurementRow: View {
    let values: [MeasuredValue]
    let accessibilityPrefix: String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(values) { value in
                ProductDetailMeasurementColumn(value: value)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(accessibilityPrefix).\(value.key)")
            }
        }
        .background(ProductInformationStyle.field)
    }
}

private struct ProductDetailMeasurementColumn: View {
    let value: MeasuredValue

    var body: some View {
        VStack(spacing: 1) {
            Text(ProductInformationStyle.measurementTitle(for: value))
                .font(.headline)
                .tracking(-0.43)
                .foregroundStyle(Color(red: 83 / 255, green: 79 / 255, blue: 73 / 255))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(ProductInformationStyle.field)
            Text(MeasurementDisplayText.centimeters(value.valueCm) + "cm").font(.subheadline)
                .tracking(-0.23)
                .foregroundStyle(.black)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 64)
                .background(.white)
        }
    }
}
