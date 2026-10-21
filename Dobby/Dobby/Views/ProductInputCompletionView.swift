import SwiftUI

struct ProductInputCompletionView: View {
    let garment: Garment
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        ScrollView {
            ProductCompletionContent(garment: garment)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(ProductInformationStyle.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProductCompletionActions(onExport: onExport, onLibrary: onLibrary)
        }
        .navigationTitle("제품 정보 입력")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ProductInformationStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("product-complete.screen")
    }
}

private struct ProductCompletionContent: View {
    let garment: Garment

    var body: some View {
        VStack(spacing: 24) {
            ProductCompletionHeader()
            ProductCompletionCard(garment: garment)
        }
    }
}

private struct ProductCompletionHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("제품 정보 입력 완료! 🎉").font(.system(size: 20, weight: .bold))
            Text("보관함에서 저장한 옷을 확인할 수 있어요")
                .font(.system(size: 16, weight: .medium))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

private struct ProductCompletionCard: View {
    let garment: Garment

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ProductSummaryField(title: "제품명", text: garment.name)
            ProductCompletionPhotoSection(garment: garment)
            ProductSummaryField(title: "설명", text: garment.detail)
            if !garment.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ProductSummaryField(title: "브랜드", text: garment.brand)
            }
            ProductSummaryField(title: "가격", text: garment.price.map {
                $0.formatted(.number.locale(Locale(identifier: "ko_KR")))
            } ?? "")
            ProductSummaryMeasurements(garment: garment)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("product-complete.measurements")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct ProductSummaryField: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: title)
            Text(text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProductCompletionPhotoSection: View {
    let garment: Garment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "제품 사진")
            ProductCompletionPhotos(garment: garment)
        }
    }
}

private struct ProductCompletionPhotos: View {
    let garment: Garment

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductCompletionPhotoRow(garment: garment)
        }
    }
}

private struct ProductCompletionPhotoRow: View {
    let garment: Garment

    var body: some View {
        HStack(spacing: 8) {
            ForEach(garment.productPhotos) { photo in
                ProductCompletionPhoto(photo: photo)
            }
        }
    }
}

private struct ProductCompletionPhoto: View {
    let photo: GarmentPhoto
    @State private var isExpanded = false

    var body: some View {
        Button { isExpanded = true } label: {
            StoredProductPhotoView(photo: photo, maximumPixelSize: 640)
                .frame(width: 152, height: 212)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12)).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.2), in: Circle()).padding(10)
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

private struct ProductSummaryMeasurements: View {
    let garment: Garment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "실측 사이즈")
            if garment.visibleMeasurements.contains(where: {
                $0.sourceStatusRaw == MeasurementStatus.uncertain.rawValue && !$0.isEdited
            }) {
                Text("불확실한 자동 측정값이 포함되어 있어요.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ProductSummaryMeasurementScroll(values: ProductInformationStyle.measurements(for: garment))
        }
    }
}

private struct ProductSummaryMeasurementScroll: View {
    let values: [MeasuredValue]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductSummaryMeasurementRow(values: values)
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width, CGFloat(values.count) * 64)
                }
        }
        .background(ProductInformationStyle.field)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(Color(white: 0.88), lineWidth: 1)
        }
    }
}

private struct ProductSummaryMeasurementRow: View {
    let values: [MeasuredValue]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(values) { value in
                ProductSummaryMeasurementColumn(value: value)
            }
        }
        .background(Color(white: 0.88))
    }
}

private struct ProductSummaryMeasurementColumn: View {
    let value: MeasuredValue

    var body: some View {
        VStack(spacing: 1) {
            Text(ProductInformationStyle.measurementTitle(for: value)).font(.headline).foregroundStyle(Color("BrandNeutral800"))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 42).background(.white)
            Text(MeasurementDisplayText.centimeters(value.valueCm) + "cm").font(.subheadline)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(ProductInformationStyle.field)
        }
    }
}

private struct ProductCompletionActions: View {
    let onExport: () -> Void
    let onLibrary: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onExport) {
                Text("플랫폼에 업로드하러 가기").frame(maxWidth: .infinity).frame(height: 62)
                    .foregroundStyle(.white)
                    .background(ProductInformationStyle.upload, in: Capsule())
            }
            .accessibilityIdentifier("product-complete.export")
            Button(action: onLibrary) {
                Text("보관함으로 이동하기").frame(maxWidth: .infinity).frame(height: 62)
                    .foregroundStyle(Color(red: 69 / 255, green: 33 / 255, blue: 7 / 255))
                    .background(Color(red: 248 / 255, green: 241 / 255, blue: 237 / 255), in: Capsule())
            }
            .accessibilityIdentifier("product-complete.library")
        }
        .font(.callout.weight(.semibold))
        .buttonStyle(.plain)
        .padding(.horizontal, 33)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(red: 1, green: 249 / 255, blue: 246 / 255).ignoresSafeArea(edges: .bottom))
    }
}
