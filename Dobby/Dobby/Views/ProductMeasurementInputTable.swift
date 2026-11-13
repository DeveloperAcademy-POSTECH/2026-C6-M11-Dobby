import SwiftUI
import UIKit

struct ProductMeasurementInputTable: View {
    let garment: Garment
    @Binding var measurementInput: GarmentMeasurementInputState
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "실측 사이즈")
                .frame(minHeight: 22, alignment: .leading)
            let missingValues = garment.visibleMeasurements.filter {
                !GarmentMeasurementInputText.hasUsableValue($0, drafts: measurementInput.drafts)
            }
            if !missingValues.isEmpty {
                Label("\(missingValues.map(\.displayLabel).joined(separator: ", ")): 계산된 길이가 없어요. 치수를 입력하거나 실측 결과에서 실패 이유를 확인해 주세요.",
                    systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("product-info.measurement-warning")
            }
            ProductMeasurementScroll(columns: ProductInformationStyle.measurements(for: garment),
                measurementInput: $measurementInput, focus: focus)
        }
    }
}

private struct ProductMeasurementScroll: View {
    let columns: [MeasuredValue]
    @Binding var measurementInput: GarmentMeasurementInputState
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ProductMeasurementRow(columns: columns, measurementInput: $measurementInput, focus: focus)
                .padding(1.5)
                .containerRelativeFrame(.horizontal) { width, _ in
                    columns.count <= 5 ? width : max(width, CGFloat(columns.count) * 85 - 1)
                }
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollDisabled(columns.count <= 5)
        .background(Color("BrandNeutral100"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color("BrandNeutral100"), lineWidth: 1.5)
        }
        .accessibilityIdentifier("product-info.measurements")
        .productInputInteractionArea()
    }
}

private struct ProductMeasurementRow: View {
    let columns: [MeasuredValue]
    @Binding var measurementInput: GarmentMeasurementInputState
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, value in
                if index > 0 {
                    Rectangle().fill(Color("BrandNeutral100")).frame(width: 1)
                }
                SizeColumn(value: value, text: Binding(
                    get: { measurementInput.text(for: value) },
                    set: { measurementInput.setText($0, for: value) }
                ), focus: focus, isCompact: columns.count <= 5)
                .frame(maxWidth: columns.count <= 5 ? .infinity : nil)
            }
        }
    }
}

private struct SizeColumn: View {
    @Bindable var value: MeasuredValue

    @Binding var text: String
    let focus: FocusState<UUID?>.Binding
    let isCompact: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(value.key == "totalLength" ? "총장" : ProductInformationStyle.measurementTitle(for: value))
                .font(.custom("Pretendard-SemiBold", size: 17, relativeTo: .headline))
                .tracking(-0.43)
                .foregroundStyle(Color("BrandNeutral800"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color("BrandNeutral100"))

            ProductMeasurementNumber(value: value, text: $text, focus: focus)
        }
        .frame(minWidth: isCompact ? 0 : 84)
    }
}

private struct ProductMeasurementNumber: View {
    let value: MeasuredValue
    @Binding var text: String
    let focus: FocusState<UUID?>.Binding

    @ScaledMetric(relativeTo: .subheadline) private var valueFontSize: CGFloat = 15

    private var inputWidth: CGFloat {
        if text.isEmpty { return 24 }
        let font = UIFont(name: "Pretendard-Regular", size: valueFontSize) ?? UIFont.systemFont(ofSize: valueFontSize)
        return min(58, max(1, ceil((text as NSString).size(withAttributes: [.font: font, .kern: -0.23]).width)))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            TextField("", text: $text)
                .accessibilityLabel("\(value.displayLabel) 센티미터")
                .accessibilityIdentifier("product-info.measurement.\(value.key)")
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .focused(focus, equals: value.id)
                .frame(width: inputWidth)
                .font(.custom("Pretendard-Regular", size: 15, relativeTo: .subheadline))
            Text("cm")
        }
        .font(.custom("Pretendard-Regular", size: 15, relativeTo: .subheadline))
        .tracking(-0.23)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .foregroundStyle(Color("BrandNeutralBlack"))
        .background(Color("BrandNeutralWhite"))
    }
}
