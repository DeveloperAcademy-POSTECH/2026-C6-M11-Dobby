import PhotosUI
import SwiftUI
import UIKit

/// A photo-only check of the selected garment model. The View owns the
/// selection and presentation state; inference remains in the provider actor.
struct GarmentRecognitionView: View {
    let provider: CoreMLGarmentLandmarkProvider
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var recognition: GarmentPhotoRecognition?
    @State private var image: UIImage?
    @State private var isRecognizing = false
    @State private var errorMessage: String?
    @State private var requestID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(provider.kind.supportDescription) 인식 테스트").font(.title2.bold())
                        Text(photoGuidance)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label("사진에서는 인식점만 확인합니다. 깊이 정보가 없어 cm 치수는 계산하지 않습니다.", systemImage: "photo.badge.checkmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                        Label("\(provider.kind.title) 사진 선택", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(provider.kind == .bottoms ? "pickBottomPhoto" : "pickTopPhoto")

                    if isRecognizing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("사진에서 \(provider.kind.title) 인식점을 찾고 있습니다…").font(.subheadline)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(identifierPrefix + "Status")
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier(identifierPrefix + "Error")
                    } else if recognition == nil {
                        ContentUnavailableView("\(provider.kind.title) 사진을 선택해 주세요", systemImage: "photo", description: Text("옷 전체와 모든 측정점이 보이는 사진을 선택해 주세요."))
                            .accessibilityIdentifier(identifierPrefix + "Empty")
                    }

                    if let recognition, let image {
                        resultContent(recognition, image: image)
                            .accessibilityIdentifier(identifierPrefix + "Result")
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("\(provider.kind.title) 사진 인식")
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
        .accessibilityIdentifier(identifierPrefix + "Screen")
    }

    private var identifierPrefix: String { provider.kind == .bottoms ? "bottomRecognition" : "topRecognition" }

    private var photoGuidance: String {
        provider.kind == .top
            ? "긴팔·반팔 상의와 소매를 바닥에 평평하게 펼친 사진을 선택해 주세요. 옷걸이 사진은 지원하지 않으며, 민소매의 소매끝 점은 사용할 수 없습니다."
            : "바지·반바지 한 벌을 펼치고 허리가 위, 밑단이 아래로 보이는 사진을 선택해 주세요. 치마는 지원하지 않습니다."
    }

    private func resultContent(_ result: GarmentPhotoRecognition, image: UIImage) -> some View {
        let points = orderedPoints(result)
        return VStack(alignment: .leading, spacing: 14) {
            GarmentRecognitionOverlay(image: image, imageSize: result.imageSize, points: points,
                                     skeleton: provider.skeleton)
                .accessibilityLabel("사진 위에 \(provider.kind.title) 측정 후보점을 번호로 표시한 결과")

            HStack {
                Text(String(format: "탐지 신뢰도 %.0f%%", result.detectionConfidence * 100))
                Spacer()
                Text(String(format: "%.2f초", result.durationSeconds))
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityIdentifier(identifierPrefix + "Confidence")
            Text("측정 후보점 \(result.points.filter { provider.keypoints.contains($0.id) && ($0.confidence ?? 0) >= 0.5 }.count)/\(provider.keypoints.count)개 · 신뢰도 50% 이상")
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

    private func orderedPoints(_ result: GarmentPhotoRecognition) -> [GarmentLandmark] {
        let keys = provider.keypoints
        return keys.compactMap { key in result.points.first { $0.id == key } }
            + result.points.filter { !keys.contains($0.id) }
    }

    private func label(for id: String) -> String {
        let derivedName = id == "waist_center" ? "허리 중앙" : id == "neck_center" ? "목 중앙"
            : id == "top_length_start" ? "총장 상단" : id
        let name = provider.labels[id]?.first ?? derivedName
        if id == "top_length_start" { return "\(name) · 옷 윤곽에서 계산" }
        return ["waist_center", "neck_center"].contains(id) ? "\(name) · 양 끝점에서 계산" : name
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
                throw GarmentPhotoDisplayError.unreadablePhoto
            }
            guard !Task.isCancelled, requestID == activeID, selection == item else { return }
            let result = try await provider.recognizePhoto(data)
            guard !Task.isCancelled, requestID == activeID, selection == item else { return }
            guard let decodedImage = UIImage(data: result.imageJPEG) else {
                throw GarmentPhotoDisplayError.unreadablePhoto
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

private enum GarmentPhotoDisplayError: LocalizedError {
    case unreadablePhoto
    var errorDescription: String? { "선택한 사진을 읽을 수 없습니다. 다른 사진을 선택해 주세요." }
}

private struct GarmentRecognitionOverlay: View {
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
