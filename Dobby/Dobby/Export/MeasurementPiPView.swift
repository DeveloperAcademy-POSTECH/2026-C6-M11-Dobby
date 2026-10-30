import SwiftUI

struct MeasurementPiPView: View {
    static let size = CGSize(width: 379, height: 202)

    let measurements: [ExportMeasurement]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("MeasurementPiPBackground")
                .resizable()
                .frame(width: Self.size.width, height: Self.size.height)
            Text("실측 사이즈를 보고 바로 입력해요")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 27)
                .padding(.top, 40)
            VStack(spacing: 0) {
                Color.clear.frame(height: 106)
                MeasurementPiPRow(measurements: measurements, content: { measurement in
                    Text(measurement.title)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white)
                })
                MeasurementPiPRow(measurements: measurements, content: { measurement in
                    Text("\(measurement.displayValue)cm")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                })
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .light)
    }
}

private struct MeasurementPiPRow<Content: View>: View {
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
        .frame(height: 48)
    }
}

#Preview("상의 4개") {
    MeasurementPiPView(measurements: .topPreview)
        .padding()
}

#Preview("하의 5개") {
    MeasurementPiPView(measurements: .bottomPreview)
        .padding()
}

private extension Array where Element == ExportMeasurement {
    static let topPreview = [
        ExportMeasurement(id: "shoulder", title: "어깨", value: "56"),
        ExportMeasurement(id: "chest", title: "가슴", value: "55"),
        ExportMeasurement(id: "length", title: "기장", value: "68"),
        ExportMeasurement(id: "sleeve", title: "소매", value: "52")
    ]

    static let bottomPreview = [
        ExportMeasurement(id: "waist", title: "허리", value: "38"),
        ExportMeasurement(id: "rise", title: "밑위", value: "30"),
        ExportMeasurement(id: "thigh", title: "허벅지", value: "32"),
        ExportMeasurement(id: "hem", title: "밑단", value: "22"),
        ExportMeasurement(id: "length", title: "총장", value: "102")
    ]
}
