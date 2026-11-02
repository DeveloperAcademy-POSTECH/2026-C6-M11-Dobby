import PhotosUI
import SwiftUI
import UIKit

struct OuterwearLandmarkComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var preview: UIImage?
    @State private var report: OuterwearComparisonReport?
    @State private var selectedVariant: OuterwearComparisonVariant = .original
    @State private var running = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var runID = UUID()
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("같은 사진으로 Luna의 세 가지 입력 방식을 비교합니다. 11개 측정점과 앞면 총장 시작점을 확인할 수 있습니다.")
                        .font(.subheadline)
                    Text("A 전체 사진 · B 옷 영역 크롭 · C 부위 확대 재검토\n모델·점 정의·추론 설정은 동일합니다. 사진 비교에서는 cm를 계산하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("비교할 아우터 사진 선택", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).disabled(running)
                        .accessibilityIdentifier("pickOuterwearComparisonPhoto")
                    if loading { ProgressView("사진을 불러오고 있어요") }
                    Text("자동 분류 대상: 아우터·후드가 달린 아우터·Hoodie·Sweater")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { start() } label: {
                        Label("같은 사진으로 A/B/C 비교", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(photoData == nil || loading || running)
                        .accessibilityIdentifier("runOuterwearComparison")
                    Text("한 번 비교할 때 AI 요청을 최대 3회 사용합니다. C는 B 결과를 이어받아 실행합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if running {
                        ProgressView("\(report?.results.count ?? 0)/3 완료 · 비교 중")
                        Button("비교 중단") { cancel() }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange).font(.subheadline) }
                    if let report {
                        Text("자동 분류: \(report.category) · 동일 사진 / 동일 마스크")
                            .font(.caption).foregroundStyle(.secondary)
                        if let scores = report.classifierScores, !scores.isEmpty {
                            Text("분류 점수: " + scores.prefix(3).map {
                                "\($0.label) \(String(format: "%.3f", $0.confidence))"
                            }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(report.results) { result in
                            HStack {
                                Text(result.variant.title).font(.subheadline.bold())
                                Spacer()
                                Text(result.requestError == nil ? String(format: "%.1f초", result.durationSeconds) : "요청 실패")
                                    .font(.caption.monospacedDigit())
                            }
                        }
                        Picker("비교 결과", selection: $selectedVariant) {
                            Text("A 기존").tag(OuterwearComparisonVariant.original)
                            Text("B 크롭").tag(OuterwearComparisonVariant.garmentCrop)
                            Text("C 확대").tag(OuterwearComparisonVariant.localRefinement)
                        }.pickerStyle(.segmented)
                        if let result = report.results.first(where: { $0.variant == selectedVariant }) {
                            resultContent(result, report: report)
                        } else {
                            Text("아직 이 방식의 결과가 없습니다.").foregroundStyle(.secondary)
                        }
                        if let url = try? OuterwearLandmarkComparisonRunner.fileURL(report.id) {
                            ShareLink("비교 기록 공유", item: url)
                            Text("입력 사진·확대 영역·AI 원본 응답·복원 좌표·제외 사유·처리 시간이 기기에 자동 저장됩니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("아우터 AI 비교 실험").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { cancel(); dismiss() } } }
                .task(id: selection) { await loadPhoto() }
                .onDisappear { cancel() }
        }.tint(.teal)
    }

    @ViewBuilder private func resultContent(_ result: OuterwearComparisonResult, report: OuterwearComparisonReport) -> some View {
        if let message = result.requestError { Text(message).foregroundStyle(.orange) }
        if let response = result.response, let preview {
            let observations = OuterwearComparisonGeometry.observations(response)
            let keys = TopLandmarkSchema.expectedKeypoints + (response.isFrontOnly
                ? ["top_length_start"] : ["top_length_start", "front_length_start"])
            ZStack {
                Image(uiImage: preview).resizable().scaledToFit()
                Canvas { context, size in
                    for (index, id) in keys.enumerated() {
                        guard let point = observations[id]?.point else { continue }
                        let center = CGPoint(x: point.x * size.width, y: point.y * size.height)
                        let color: Color = pointColor(id, result: result)
                        let marker = Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
                        context.fill(marker, with: .color(color))
                        context.stroke(marker, with: .color(.white), lineWidth: 1.5)
                        let label = index < 11 ? "\(index + 1)" : response.isFrontOnly ? "총" : index == 11 ? "뒤" : "앞"
                        context.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(.white), at: center)
                    }
                }
            }.aspectRatio(CGFloat(report.sourceSize.width) / CGFloat(report.sourceSize.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("청록: 검증 통과 · 주황: 제외/검증 미완료\n옷 밖의 원본 좌표도 표시합니다. 색상은 위치 정확도를 보증하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("AI 반환 \(response.points.values.filter { $0.point != nil }.count)/11점 · 총장 상단점 \(response.totalLengthStart.point == nil ? "없음" : "있음")")
                .font(.subheadline.bold())
            if let validationError = result.validationError { Text("검증: " + validationError).font(.caption).foregroundStyle(.orange) }
            ForEach(Array(keys.enumerated()), id: \.element) { index, id in
                HStack(alignment: .top) {
                    Text(index < 11 ? "\(index + 1). \(MeasurementLandmarkName.title(id))" : MeasurementLandmarkName.title(id))
                    Spacer()
                    Text(status(id, observation: observations[id], result: result))
                        .foregroundStyle(pointColor(id, result: result)).multilineTextAlignment(.trailing)
                }.font(.caption)
            }
        }
        if result.variant == .localRefinement {
            Text(String(format: "C 총 시간 %.1f초 = B + 확대 요청 %.1f초", result.durationSeconds, result.incrementalSeconds))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func pointColor(_ id: String, result: OuterwearComparisonResult) -> Color {
        result.diagnostics?.pointAssessments.first(where: { $0.landmarkID == id })?.status == .associated ? .teal : .orange
    }

    private func status(_ id: String, observation: OuterwearLandmarkObservation?, result: OuterwearComparisonResult) -> String {
        guard let observation else { return "관측 없음" }
        guard observation.point != nil else { return observation.visibility == .occluded ? "AI: 가려짐" : "AI: 위치 불확실" }
        guard let assessment = result.diagnostics?.pointAssessments.first(where: { $0.landmarkID == id }) else { return "좌표 반환 · 검증 미완료" }
        switch assessment.status {
        case .associated: return "검증 통과"
        case .outsideMask: return "좌표가 마스크 밖"
        default: return "끝점 기준에서 제외"
        }
    }

    private func loadPhoto() async {
        cancel()
        let active = UUID(); runID = active
        photoData = nil; preview = nil; report = nil; errorMessage = nil; loading = false
        guard let selection else { return }
        loading = true
        defer { if runID == active { loading = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self), let decoded = UIImage(data: data) else {
                throw OuterwearLandmarkClientError.invalidImage
            }
            guard !Task.isCancelled, runID == active else { return }
            photoData = data; preview = decoded
        } catch {
            guard !Task.isCancelled, runID == active else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func start() {
        guard let data = photoData, !running else { return }
        let active = UUID(); runID = active
        running = true; report = nil; errorMessage = nil; selectedVariant = .original
        task = Task {
            defer { if runID == active { running = false; task = nil } }
            do {
                _ = try await OuterwearLandmarkComparisonRunner().run(data: data) { update in
                    await MainActor.run {
                        guard runID == active else { return }
                        report = update
                        preview = UIImage(data: update.sourceJPEG)
                    }
                }
            } catch {
                guard !Task.isCancelled, runID == active else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() { task?.cancel(); task = nil; runID = UUID(); running = false }
}
