import PhotosUI
import SwiftUI
import UIKit

/// A photo-only check of the bundled bottom landmark model. The View owns the
/// selection and presentation state; inference remains in the provider actor.
struct BottomRecognitionView: View {
    let provider: CoreMLBottomLandmarkProvider
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var recognition: BottomPhotoRecognition?
    @State private var image: UIImage?
    @State private var isRecognizing = false
    @State private var errorMessage: String?
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("바지·반바지 인식 테스트").font(.title2.bold())
                        Text("바지·반바지 한 벌을 펼치고 허리가 위, 밑단이 아래로 보이는 사진을 선택해 주세요. 치마는 지원하지 않습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label("사진에서는 인식점만 확인합니다. 깊이 정보가 없어 cm 치수는 계산하지 않습니다.", systemImage: "photo.badge.checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                        Label("하의 사진 선택", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pickBottomPhoto")

                    if isRecognizing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("사진에서 하의 인식점을 찾고 있습니다…").font(.subheadline)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("bottomRecognitionStatus")
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("bottomRecognitionError")
                    } else if recognition == nil {
                        ContentUnavailableView("하의 사진을 선택해 주세요", systemImage: "photo", description: Text("옷 전체와 허리·밑단이 모두 보이는 사진이 좋습니다."))
                            .accessibilityIdentifier("bottomRecognitionEmpty")
                    }

                    if let recognition, let image {
                        resultContent(recognition, image: image)
                            .accessibilityIdentifier("bottomRecognitionResult")
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("하의 사진 인식")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .task(id: selection) { await recognizeSelection(selection) }
            .onDisappear {
                // The task is also cancelled by SwiftUI. Invalidating identity
                // rejects results even if an inference backend returns late.
                requestID = UUID()
                isRecognizing = false
            }
        }
        .tint(.teal)
        .accessibilityIdentifier("bottomRecognitionScreen")
    }

    private func resultContent(_ result: BottomPhotoRecognition, image: UIImage) -> some View {
        let points = orderedPoints(result)
        return VStack(alignment: .leading, spacing: 14) {
            BottomRecognitionOverlay(image: image, imageSize: result.imageSize, points: points,
                                     skeleton: provider.schema.skeleton)
                .accessibilityLabel("사진 위에 하의 측정 후보점을 번호로 표시한 결과")

            HStack {
                Text(String(format: "하의 탐지 신뢰도 %.0f%%", result.detectionConfidence * 100))
                Spacer()
                Text(String(format: "%.2f초", result.durationSeconds))
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityIdentifier("bottomRecognitionConfidence")
            Text("측정 후보점 \(result.points.filter { provider.schema.keypoints.contains($0.id) && ($0.confidence ?? 0) >= 0.5 }.count)/\(provider.schema.keypoints.count)개 · 신뢰도 50% 이상")
                .font(.subheadline.bold())
            Text("주황색은 신뢰도 50% 미만 또는 신뢰도 정보가 없는 점입니다. 신뢰도는 실제 위치·치수의 정확도를 보증하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, landmark in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(confidenceColor(landmark), in: Circle())
                        Text(label(for: landmark.id)).font(.subheadline)
                        Spacer()
                        Text(landmark.confidence.map { String(format: "%.0f%%", $0 * 100) } ?? "정보 없음")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            Text("모델 \(result.modelVersion)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func orderedPoints(_ result: BottomPhotoRecognition) -> [GarmentLandmark] {
        let keys = provider.schema.keypoints
        return keys.compactMap { key in result.points.first { $0.id == key } }
            + result.points.filter { !keys.contains($0.id) }
    }

    private func label(for id: String) -> String {
        let name = provider.schema.labels[id]?.first ?? (id == "waist_center" ? "허리 중앙" : id)
        return id == "waist_center" ? "\(name) · 양 끝점에서 계산" : name
    }

    private func confidenceColor(_ landmark: GarmentLandmark) -> Color {
        (landmark.confidence ?? 0) >= 0.5 ? .teal : .orange
    }

    private func recognizeSelection(_ item: PhotosPickerItem?) async {
        let activeID = UUID()
        requestID = activeID
        recognition = nil
        image = nil
        errorMessage = nil
        guard let item else { isRecognizing = false; return }
        isRecognizing = true
        defer { if requestID == activeID { isRecognizing = false } }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw BottomPhotoDisplayError.unreadablePhoto
            }
            guard !Task.isCancelled, requestID == activeID, selection == item else { return }
            let result = try await provider.recognizePhoto(data)
            guard !Task.isCancelled, requestID == activeID, selection == item else { return }
            guard let decodedImage = UIImage(data: result.imageJPEG) else {
                throw BottomPhotoDisplayError.unreadablePhoto
            }
            // Decode the normalized JPEG once, not during each body evaluation.
            image = decodedImage
            recognition = result
        } catch {
            guard !Task.isCancelled, requestID == activeID, selection == item else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private enum BottomPhotoDisplayError: LocalizedError {
    case unreadablePhoto
    var errorDescription: String? { "선택한 사진을 읽을 수 없습니다. 다른 사진을 선택해 주세요." }
}

private struct BottomRecognitionOverlay: View {
    let image: UIImage
    let imageSize: PixelSize
    let points: [GarmentLandmark]
    let skeleton: [[String]]

    private var aspectRatio: CGFloat {
        guard imageSize.isValid else { return 1 }
        return CGFloat(imageSize.width) / CGFloat(imageSize.height)
    }

    var body: some View {
        ZStack {
            Image(uiImage: image).resizable().scaledToFit()
            Canvas { context, size in
                func position(_ point: ImagePoint) -> CGPoint {
                    CGPoint(x: point.x * size.width, y: point.y * size.height)
                }
                let visiblePoints = points.filter { $0.isVisible && $0.point.isValid }
                for connection in skeleton {
                    guard connection.count == 2,
                          let first = visiblePoints.first(where: { $0.id == connection[0] }),
                          let second = visiblePoints.first(where: { $0.id == connection[1] }) else { continue }
                    var path = Path()
                    path.move(to: position(first.point))
                    path.addLine(to: position(second.point))
                    context.stroke(path, with: .color(.white), lineWidth: 3)
                    context.stroke(path, with: .color(.teal), lineWidth: 1.5)
                }
                for (index, landmark) in points.enumerated() where landmark.isVisible && landmark.point.isValid {
                    let center = position(landmark.point)
                    let color: Color = (landmark.confidence ?? 0) >= 0.5 ? .teal : .orange
                    let marker = Path(ellipseIn: CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22))
                    context.fill(marker, with: .color(color))
                    context.stroke(marker, with: .color(.white), lineWidth: 1.5)
                    context.draw(Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white), at: center)
                }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
