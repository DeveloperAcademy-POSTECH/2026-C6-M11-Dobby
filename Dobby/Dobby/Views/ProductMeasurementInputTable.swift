import SwiftUI

struct ProductMeasurementInputTable: View {
    let garment: Garment
    @Binding var measurementInput: GarmentMeasurementInputState
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProductFieldTitle(title: "실측 사이즈")
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
                .containerRelativeFrame(.horizontal) { width, _ in
                    columns.count <= 5 ? width : max(width, CGFloat(columns.count) * 85 - 1)
                }
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollDisabled(columns.count <= 5)
        .background(ProductInformationStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).stroke(ProductInformationStyle.field, lineWidth: 1.5)
        }
        .accessibilityIdentifier("product-info.measurements")
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
                    Rectangle().fill(ProductInformationStyle.field).frame(width: 1)
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
        VStack(spacing: 0) {
            Text(ProductInformationStyle.measurementTitle(for: value))
                .font(.headline)
                .foregroundStyle(Color(white: 0.32))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(ProductInformationStyle.field)

            ProductMeasurementNumber(value: value, text: $text, focus: focus)
        }
        .frame(minWidth: isCompact ? 0 : 84)
    }
}

private struct ProductMeasurementNumber: View {
    let value: MeasuredValue
    @Binding var text: String
    let focus: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            TextField("", text: $text)
                .accessibilityLabel("\(value.displayLabel) 센티미터")
                .accessibilityIdentifier("product-info.measurement.\(value.key)")
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .focused(focus, equals: value.id)
                .frame(width: min(58, max(24, CGFloat(text.count) * 10 + 6)))
                .monospacedDigit()
            Text("cm")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
    }
}
