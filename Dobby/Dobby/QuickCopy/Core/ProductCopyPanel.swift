import SwiftUI

struct ProductCopyControlLabel: View {
    let field: ProductCopyField
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc").foregroundStyle(.orange)
            Text(field.title).font(.caption2.weight(.medium)).foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 10)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12)) }
    }
}

struct ProductCopyPanel: View {
    let sessionID: UUID
    let values: ProductCopyValues
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { control(.productName); control(.description) }
            if let items = values.measurementItems, !items.isEmpty {
                ProductMeasurementTable(items: items)
            } else {
                HStack(spacing: 8) { control(.brand); control(.measurements) }
            }
        }
    }
    private func control(_ field: ProductCopyField) -> some View {
        Group {
            if let url = ForegroundCopyURLBuilder.url(for: field) {
                Link(destination: url) {
                    ProductCopyControlLabel(field: field)
                }
            } else {
                ProductCopyControlLabel(field: field)
                    .opacity(0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ProductMeasurementTable: View {
    let items: [ProductCopyMeasurement]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { item in
                        VStack(spacing: 0) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(Color(white: 0.12))
                            Text("\(item.value)cm")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .background(.black)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.12))
                }
                .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("상품 실측 정보")
    }

    /// 한 줄에 최대 6개를 표시하고, 더 많은 실측값은 다음 줄로 이어서 보여준다.
    private var rows: [[ProductCopyMeasurement]] {
        stride(from: 0, to: items.count, by: 6).map { start in
            Array(items[start..<min(start + 6, items.count)])
        }
    }
}
