// Created by mason on 10/20/26.
import SwiftUI

/// 확정 결과의 표시만 재사용한다. 계산·수정·저장이나 별도 사진 생성은 하지 않는다.
struct MeasurementGalleryPhotoView: View {
    let record: SavedMeasurement
    var isThumbnail = false
    @State private var image: UIImage?

    var body: some View {
        let measurement = AutomaticMeasurement(record: record)
        let values = measurement.visibleValues
        GeometryReader { geometry in
            let ratio = SnapshotPresentation.aspectRatio(for: record.snapshot)
            let width = isThumbnail ? max(geometry.size.width, geometry.size.height * ratio)
                : min(geometry.size.width, geometry.size.height * ratio)
            // 썸네일에서도 라벨과 선을 사진과 함께 축소한다.
            preview(measurement)
                .frame(width: 402, height: 402 / ratio)
                .scaleEffect(width / 402)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("실측값 표시 사진")
        .accessibilityValue(values.map { "\($0.title) \(GarmentMeasurementText.value($0))" }.joined(separator: ", "))
        .accessibilityIdentifier("camera.galleryMeasurement")
        .task(id: record.id) {
            image = await SnapshotPresentation.thumbnail(for: record.snapshot, maximumDimension: isThumbnail ? 256 : 1600)
        }
    }

    private func preview(_ measurement: AutomaticMeasurement) -> some View {
        var landmarks = record.landmarks
        landmarks.points = [] // 편집 핸들·돋보기 없이 결과 선과 값만 표시한다.
        return GarmentMeasurementPhotoEditor(image: image, snapshot: record.snapshot,
            editableLandmarks: landmarks, definitions: measurement.visibleDefinitions,
            values: measurement.visibleValues, showLabels: true, isEnabled: false,
            isRecalculating: false, showsEnlargeControl: false,
            usesResultPointStyleForEndpoints: true,
            onEnlarge: {}, onMove: { _, _ in }, onEditingChanged: { _ in })
    }
}
