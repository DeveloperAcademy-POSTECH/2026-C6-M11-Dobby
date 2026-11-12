import SwiftUI

struct MeasurementPiPView: View {
    static let renderSize = CGSize(width: 379, height: 202)

    let measurements: [ExportMeasurement]

    var body: some View {
        VStack(spacing: 0) {
            MeasurementPiPHeader()
            MeasurementPiPTable(measurements: measurements)
        }
        .frame(width: Self.renderSize.width, height: Self.renderSize.height)
        .background(.brandMain600)
        .environment(\.colorScheme, .light)
    }
}

private struct MeasurementPiPHeader: View {
    private static let headerHeight: CGFloat = 106

    var body: some View {
        Image("MeasurementPiPHeaderGraphic")
            .resizable()
            .frame(
                width: MeasurementPiPView.renderSize.width,
                height: Self.headerHeight
            )
            .overlay(alignment: .top) {
                Text("실측 사이즈를 보고 바로 입력해요")
                    .font(.custom("Pretendard-Bold", fixedSize: 24))
                    .foregroundStyle(.white)
                    .padding(.top, 41)
                    .padding(.horizontal, 27)
            }
            .background(.brandMain500)
    }
}

private struct MeasurementPiPTable: View {
    private static let tableHeight: CGFloat = 96

    let measurements: [ExportMeasurement]

    var body: some View {
        VStack(spacing: 0) {
            MeasurementPiPRow(measurements: measurements) { measurement in
                Text(measurement.title)
                    .font(.custom("Pretendard-Medium", fixedSize: 17))
                    .foregroundStyle(.white)
            }
            MeasurementPiPRow(measurements: measurements) { measurement in
                Text("\(measurement.displayValue)cm")
                    .font(.custom("Pretendard-Bold", fixedSize: 17))
                    .foregroundStyle(.black)
            }
            .background(Color("BrandNeutral50"))
        }
        .frame(height: Self.tableHeight)
    }
}

private struct MeasurementPiPRow<Content: View>: View {
    private static var rowHeight: CGFloat { 48 }

    let measurements: [ExportMeasurement]
    @ViewBuilder let content: (ExportMeasurement) -> Content

    var body: some View {
        HStack(spacing: 0) {
            ForEach(measurements) { measurement in
                content(measurement)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
    }
}

#Preview("상의 4개") {
    MeasurementPiPView(measurements: .upperBodyPreviewMeasurements)
        .padding()
}

#Preview("하의 5개") {
    MeasurementPiPView(measurements: .lowerBodyPreviewMeasurements)
        .padding()
}

private extension Array where Element == ExportMeasurement {
    static let upperBodyPreviewMeasurements = [
        ExportMeasurement(id: "shoulder", title: "어깨", value: "56"),
        ExportMeasurement(id: "chest", title: "가슴", value: "55"),
        ExportMeasurement(id: "length", title: "기장", value: "68"),
        ExportMeasurement(id: "sleeve", title: "소매", value: "52")
    ]

    static let lowerBodyPreviewMeasurements = [
        ExportMeasurement(id: "waist", title: "허리", value: "38"),
        ExportMeasurement(id: "rise", title: "밑위", value: "30"),
        ExportMeasurement(id: "thigh", title: "허벅지", value: "32"),
        ExportMeasurement(id: "hem", title: "밑단", value: "22"),
        ExportMeasurement(id: "length", title: "총장", value: "102")
    ]
}
