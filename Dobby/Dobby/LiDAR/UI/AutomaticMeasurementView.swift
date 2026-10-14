import SwiftUI
import UIKit

/// The View owns form text, image presentation, dialogs and save feedback. The
/// value model owns the measured data and the rules for editing its references.
struct AutomaticMeasurementResultView: View {
    @State private var model: AutomaticMeasurement
    let archive: MeasurementArchive
    let recordingError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var referenceTexts: [String: String]
    @State private var image: UIImage?
    @State private var manualComparison: ManualMeasurement?
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(model: AutomaticMeasurement, archive: MeasurementArchive, recordingError: String? = nil) {
        _model = State(initialValue: model)
        _referenceTexts = State(initialValue: model.referenceByDefinitionCentimeters.mapValues { String(format: "%.2f", $0) })
        self.archive = archive
        self.recordingError = recordingError
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(model.snapshot.frame.source == .synthetic
                        ? "합성 연결 테스트 · 실제 ML 인식·센서 정확도 검증 아님"
                        : "동일 프레임의 측정점과 LiDAR 결과", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.bold()).foregroundStyle(model.snapshot.frame.source == .synthetic ? .orange : .teal)
                        .accessibilityIdentifier("automaticProvenance")
                    if model.hasPointAdjustments {
                        Label("측정점 \(model.editedPointIDs.count)개 수동 보정 · 원래 인식 위치 보존", systemImage: "hand.draw")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("automaticPointAdjustmentProvenance")
                    }
                    if let recordingError {
                        Text("계산은 완료했지만 시도 기록을 마무리하지 못했습니다. 이 시도는 통계에서 미완료로 남습니다: \(recordingError)")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    AutomaticSnapshotView(snapshot: model.snapshot, image: image, landmarks: model.displayLandmarks,
                                          definitions: model.definitions, result: model.result)
                    Text("성공한 항목은 유지하고, 미검출·깊이 부족 항목은 사유를 따로 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let diagnostics = model.landmarks.recognitionDiagnostics {
                        MeasurementRecognitionDetails(diagnostics: diagnostics)
                    }
                    ForEach(model.result.values) { value in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(value.title).font(.headline)
                                Spacer()
                                Text(value.meters.map { MeasurementDisplayText.centimeters($0 * 100) + " cm" } ?? "측정 불가")
                                    .font(.title3.monospacedDigit()).accessibilityIdentifier("automaticValue_\(value.id)")
                            }
                            Text(value.status.label).foregroundStyle(value.status == .valid ? .teal : .orange)
                            if let failure = value.failure { Text(failure.message).font(.caption).foregroundStyle(.secondary) }
                            MeasurementPointFailureDetails(value: value)
                            HStack {
                                TextField("줄자 기준값", text: Binding(get: { referenceTexts[value.id] ?? "" },
                                    set: { referenceTexts[value.id] = $0; exportedURL = nil }))
                                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("automaticReference_\(value.id)")
                                Text("cm").foregroundStyle(.secondary)
                            }
                            if let definition = model.definitions.first(where: { $0.id == value.id }), definition.landmarkIDs.count == 2 {
                                Button("이 사진에서 수동점 검증") { compareManually(definitionID: definition.id) }
                                    .font(.caption).accessibilityIdentifier("manualComparison_\(value.id)")
                            }
                        }.labCard()
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("시험 조건").font(.headline)
                        Picker("옷 종류", selection: $model.context.category) {
                            ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                        }
                        TextField("옷·물체 이름", text: $model.context.specimenName).textFieldStyle(.roundedBorder)
                        TextField("기기 모델", text: $model.context.deviceModel).textFieldStyle(.roundedBorder)
                        TextField("거리·각도·소재·배경", text: $model.context.conditions, axis: .vertical).textFieldStyle(.roundedBorder)
                        if let timing = model.timings {
                            Text(String(format: "촬영 %.3f초 · 측정점 %.3f초 · 계산 %.3f초 · 전체 %.3f초",
                                timing.captureSeconds ?? 0, timing.landmarksSeconds ?? 0,
                                timing.measurementSeconds ?? 0, timing.totalSeconds))
                                .font(.caption.monospacedDigit())
                        }
                    }.labCard()
                    Button { Task { await save() } } label: {
                        Label("전체 항목 기록 저장", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(isSaving).accessibilityIdentifier("saveAutomaticMeasurement")
                    if let url = exportedURL {
                        Text("전체 항목을 저장했습니다").foregroundStyle(.teal).accessibilityIdentifier("automaticMeasurementSaved")
                        ShareLink("사진·깊이·전체 측정점 공유", item: url)
                    }
                    Text("계산 상태는 실제 오차 보증이 아닙니다. 실측 검증은 항목별 줄자값과 같은 조건의 독립 촬영으로 진행하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).background(Color(.systemGroupedBackground))
                .navigationTitle("자동 측정 연결 결과").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .task { if image == nil { image = SnapshotPresentation.image(for: model.snapshot) } }
                .onChange(of: model.context) { _, _ in exportedURL = nil }
                .sheet(item: $manualComparison) { measurement in MeasurementDetailView(model: measurement, archive: archive) }
                .alert("기록 확인", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("확인", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.teal)
    }

    private func parsedReference(for definitionID: String) throws -> Double? {
        let text = (referenceTexts[definitionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else {
            throw AutomaticMeasurementEditError.invalidReference(definitionID)
        }
        return value
    }

    private func compareManually(definitionID: String) {
        do {
            var candidate = model
            try candidate.setReference(parsedReference(for: definitionID), for: definitionID)
            manualComparison = candidate.manualMeasurement(for: definitionID)
        } catch { errorMessage = message(for: error) }
    }

    private func save() async {
        guard !isSaving else { return }
        do {
            var edited = model
            for definition in model.definitions {
                try edited.setReference(parsedReference(for: definition.id), for: definition.id)
            }
            let record = try edited.makeRecord()
            model = edited
            let savedTexts = referenceTexts, savedContext = model.context
            isSaving = true
            defer { isSaving = false }
            let url = try await archive.save(record)
            if referenceTexts == savedTexts, model.context == savedContext { exportedURL = url }
        } catch { errorMessage = message(for: error) }
    }

    private func message(for error: Error) -> String {
        if case let AutomaticMeasurementEditError.invalidReference(id) = error {
            let title = model.definitions.first { $0.id == id }?.title ?? id
            return "\(title)의 줄자값을 0보다 큰 숫자로 입력하거나 비워 주세요."
        }
        if case AutomaticMeasurementEditError.unknownDefinition = error { return "저장할 측정 항목을 확인해 주세요." }
        return error.localizedDescription
    }
}
private struct AutomaticSnapshotView: View {
    let snapshot: CaptureSnapshot
    let image: UIImage?
    let landmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
    let result: GarmentMeasurementResult
    private var aspect: CGFloat {
        let size = snapshot.frame.imageSize
        guard size.isValid else { return 1 }
        return snapshot.frame.orientation == .right || snapshot.frame.orientation == .left
            ? CGFloat(size.height) / CGFloat(size.width) : CGFloat(size.width) / CGFloat(size.height)
    }
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            Canvas { context, size in
                func point(_ value: ImagePoint) -> CGPoint {
                    let p = ImageCoordinateTransform.originalToDisplay(value, orientation: snapshot.frame.orientation)
                    return .init(x: p.x * size.width, y: p.y * size.height)
                }
                let visible = landmarks.points.filter { $0.isVisible && $0.point.isValid }
                for definition in definitions {
                    let endpoints: [ImagePoint]
                    if definition.projection != nil {
                        guard result.sessionID == snapshot.frame.sessionID, result.frameID == snapshot.frame.frameID,
                              let value = result.values.first(where: { $0.id == definition.id }),
                              value.meters != nil, value.points.count == definition.landmarkIDs.count else { continue }
                        endpoints = value.points.map(\.imagePoint)
                    } else {
                        endpoints = definition.landmarkIDs.compactMap { id in visible.first { $0.id == id }?.point }
                    }
                    guard endpoints.count == definition.landmarkIDs.count else { continue }
                    var path = Path()
                    for (index, endpoint) in endpoints.enumerated() {
                        if index == 0 { path.move(to: point(endpoint)) }
                        else { path.addLine(to: point(endpoint)) }
                    }
                    context.stroke(path, with: .color(.yellow), lineWidth: 2)
                }
                for landmark in visible {
                    let center = point(landmark.point)
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)), with: .color(.yellow))
                }
            }
        }.aspectRatio(aspect, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
