import Combine
import SwiftUI
import UIKit

/// The production ML dependency is supplied by the app composition root. The
/// default lab has no trained model and exposes a clearly labelled fixture run.
@MainActor
final class AutomaticMeasurementViewModel: ObservableObject {
    @Published private(set) var phase: AutomaticMeasurementPhase = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var session: AutomaticMeasurementSessionModel?
    @Published var errorMessage: String?
    private let camera: ARKitCaptureProvider
    private let liveWorkflow: AutomaticMeasurementWorkflow?
    private let demoWorkflow: AutomaticMeasurementWorkflow
    private let journal = LiDARAppServices.attemptJournal
    private var activeToken: UUID?

    init(camera: ARKitCaptureProvider, provider: (any GarmentLandmarkProviding)?) {
        self.camera = camera
        liveWorkflow = provider.map {
            AutomaticMeasurementWorkflow(camera: camera, landmarks: $0, definitions: MeasurementDefinition.longSleeve,
                                         expectedLandmarkOrigin: .model)
        }
        demoWorkflow = AutomaticMeasurementWorkflow(camera: IntegrationDemoCamera(),
            landmarks: IntegrationDemoLandmarks(), definitions: IntegrationDemoLandmarks.definitions,
            expectedLandmarkOrigin: .synthetic)
    }

    var hasModel: Bool { liveWorkflow != nil }
    var phaseLabel: String {
        switch phase {
        case .idle: "촬영 준비"
        case .capturing: "사진과 깊이를 고정하는 중…"
        case .detectingLandmarks: "같은 사진에서 측정점을 받는 중…"
        case .measuring: "측정점의 실제 길이를 계산하는 중…"
        case .completed: "계산 완료"
        case .failed: "자동 측정 실패"
        case .cancelled: "자동 측정 취소"
        }
    }

    func cancel() {
        activeToken = nil
        session = nil
        phase = .cancelled
        liveWorkflow?.cancel()
        demoWorkflow.cancel()
    }

    func runDemo() async {
        do { _ = try await run(demoWorkflow, orientation: .up, synthetic: true) }
        catch is CancellationError { }
        catch let failure as AutomaticMeasurementWorkflowFailure where failure.code == .cancelled { }
        catch { errorMessage = error.localizedDescription }
    }

    func runLive(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        guard let liveWorkflow else { throw AutomaticLabError.modelNotConnected }
        return try await run(liveWorkflow, orientation: orientation, synthetic: false)
    }

    private func run(_ workflow: AutomaticMeasurementWorkflow, orientation: ImageOrientation,
                     synthetic: Bool) async throws -> CaptureSnapshot {
        guard !isRunning else { throw AutomaticLabError.alreadyRunning }
        isRunning = true
        let token = UUID()
        activeToken = token
        session = nil
        errorMessage = nil
        defer { isRunning = false; if activeToken == token { activeToken = nil } }
        let attempt = try await journal.begin(purpose: synthetic ? .fixture : .automaticModel,
            isSynthetic: synthetic, deviceContext: synthetic ? "Synthetic integration fixture" : UIDevice.current.model)
        var terminal: AutomaticMeasurementTerminalEvent?
        workflow.onPhaseChange = { [weak self] value in
            guard let self, activeToken == token else { return }
            phase = value
            if !synthetic, value == .detectingLandmarks { camera.stop() }
        }
        workflow.onTerminal = { terminal = $0 }
        do {
            try requireCurrent(token)
            let output = try await workflow.run(orientation: orientation)
            try requireCurrent(token)
            let values = output.result.values
            let outcome: MeasurementAttemptOutcome = values.allSatisfy { $0.status == .unavailable }
                ? .unavailable : (values.allSatisfy { $0.status == .valid } ? .success : .partial)
            var recordingWarning: String?
            do {
                _ = try await journal.finish(id: attempt.id, outcome: outcome, phase: .measurement,
                    sessionID: output.snapshot.frame.sessionID, frameID: output.snapshot.frame.frameID,
                    timings: Self.journalTimings(output.timings))
            } catch {
                recordingWarning = "계산은 완료했지만 시도 기록을 마무리하지 못했습니다. 이 시도는 통계에서 미완료로 남습니다: \(error.localizedDescription)"
            }
            try requireCurrent(token)
            let completed = AutomaticMeasurementSessionModel(output: output)
            completed.recordingWarning = recordingWarning
            session = completed
            return output.snapshot
        } catch {
            let failure = (error as? AutomaticMeasurementWorkflowFailure) ?? terminal?.failure
            let outcome: MeasurementAttemptOutcome
            if error is CancellationError || failure?.code == .cancelled { outcome = .cancelled }
            else if failure?.code == .timedOut { outcome = .timedOut }
            else if failure?.code == .interrupted { outcome = .interrupted }
            else if failure?.stage == .capture { outcome = .captureFailed }
            else { outcome = .landmarkFailed }
            let stage = terminal?.stage ?? failure?.stage ?? .capture
            do {
                _ = try await journal.finish(id: attempt.id, outcome: outcome,
                    phase: stage == .capture ? .capture : (stage == .landmarks ? .landmarks : .measurement),
                    sessionID: terminal?.snapshot?.frame.sessionID, frameID: terminal?.snapshot?.frame.frameID,
                    timings: terminal.map { Self.journalTimings($0.timings) } ?? .init(),
                    message: error.localizedDescription)
            } catch { errorMessage = "시도 기록 저장 오류: \(error.localizedDescription)" }
            throw error
        }
    }

    private func requireCurrent(_ token: UUID) throws {
        guard activeToken == token, !Task.isCancelled else { throw CancellationError() }
    }

    private static func journalTimings(_ value: AutomaticMeasurementTimings) -> MeasurementAttemptTimings {
        .init(captureSeconds: value.captureSeconds, landmarksSeconds: value.landmarksSeconds,
              measurementSeconds: value.measurementSeconds, totalSeconds: value.totalSeconds)
    }
}

private enum AutomaticLabError: LocalizedError {
    case modelNotConnected, alreadyRunning
    var errorDescription: String? {
        switch self {
        case .modelNotConnected: "의류 ML 모델이 아직 연결되지 않았습니다. 합성 연결 테스트 또는 수동 검증을 이용하세요."
        case .alreadyRunning: "자동 측정이 진행 중입니다. 완료하거나 취소한 뒤 다시 시작하세요."
        }
    }
}

@MainActor
private final class IntegrationDemoCamera: CaptureSnapshotProviding {
    func capture(orientation: ImageOrientation) async throws -> CaptureSnapshot {
        try Task.checkCancellation()
        var snapshot = DemoSnapshotFactory.make(.flat).snapshot
        snapshot.frame.frameID = UUID()
        snapshot.frame.capturedAt = .now
        return snapshot
    }
}

private nonisolated struct IntegrationDemoLandmarks: GarmentLandmarkProviding {
    static let definitions: [MeasurementDefinition] = [
        .testDistance,
        .init(id: "half", title: "절반 구간", landmarkIDs: ["A", "M"]),
        .init(id: "missing", title: "미검출 점 처리", landmarkIDs: ["A", "missing"])
    ]
    func landmarks(for snapshot: CaptureSnapshot) async throws -> GarmentLandmarkSet {
        try Task.checkCancellation()
        var points = SyntheticFixtures.scene().landmarks
        points.sessionID = snapshot.frame.sessionID
        points.frameID = snapshot.frame.frameID
        points.origin = .synthetic
        points.modelVersion = "integration-fixture-v1"
        let a = points.points[0].point, b = points.points[1].point
        points.points.append(.init(id: "M", point: .init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), confidence: nil))
        return points
    }
}

@MainActor
final class AutomaticMeasurementSessionModel: ObservableObject, Identifiable {
    let id = UUID()
    let snapshot: CaptureSnapshot
    let image: UIImage?
    let landmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
    let options: MeasurementOptions
    @Published private(set) var result: GarmentMeasurementResult
    @Published var references: [String: String] = [:]
    @Published var context: MeasurementTestContext
    @Published var exportedURL: URL?
    @Published var errorMessage: String?
    @Published var recordingWarning: String?
    @Published private(set) var isSaving = false
    let timingText: String?

    init(output: AutomaticMeasurementOutput) {
        snapshot = output.snapshot; landmarks = output.landmarks
        image = Self.orientedImage(output.snapshot)
        definitions = output.definitions; options = output.options; result = output.result
        context = .init(deviceModel: snapshot.frame.source == .synthetic ? "Synthetic fixture" : UIDevice.current.model)
        timingText = String(format: "촬영 %.3f초 · 측정점 %.3f초 · 계산 %.3f초 · 전체 %.3f초",
            output.timings.captureSeconds ?? 0, output.timings.landmarksSeconds ?? 0,
            output.timings.measurementSeconds ?? 0, output.timings.totalSeconds)
    }

    init(record: SavedMeasurement) {
        snapshot = record.snapshot; landmarks = record.landmarks
        image = Self.orientedImage(record.snapshot)
        definitions = record.definitions; options = record.options
        // Replayed asynchronously before presenting an imported result.
        result = record.result
        context = record.testContext ?? .init()
        timingText = nil
        references = (record.referenceByDefinitionCentimeters ?? [:]).mapValues { String(format: "%.2f", $0) }
        if definitions.count == 1, let reference = record.referenceCentimeters, references[definitions[0].id] == nil {
            references[definitions[0].id] = String(format: "%.2f", reference)
        }
    }

    func replay() async {
        result = await MeasurementPipeline().measure(snapshot: snapshot, landmarks: landmarks,
            definitions: definitions, options: options)
    }

    private static func orientedImage(_ snapshot: CaptureSnapshot) -> UIImage? {
        guard let cg = UIImage(data: snapshot.imageJPEG)?.cgImage else { return nil }
        let orientation: UIImage.Orientation
        switch snapshot.frame.orientation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    func save(to archive: MeasurementArchive) async {
        guard !isSaving else { return }
        var parsed: [String: Double] = [:]
        for definition in definitions {
            let text = (references[definition.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite, number > 0 else {
                errorMessage = "\(definition.title)의 줄자값을 0보다 큰 숫자로 입력하거나 비워 주세요."
                return
            }
            parsed[definition.id] = number
        }
        isSaving = true
        defer { isSaving = false }
        let savedReferences = references, savedContext = context
        do {
            let record = SavedMeasurement(id: UUID(), savedAt: .now, snapshot: snapshot, landmarks: landmarks,
                definitions: definitions, result: result, referenceCentimeters: nil, options: options,
                testContext: context, referenceByDefinitionCentimeters: parsed)
            let url = try await archive.save(record)
            if references == savedReferences, context == savedContext { exportedURL = url }
        } catch { errorMessage = error.localizedDescription }
    }
}

struct AutomaticMeasurementResultView: View {
    @ObservedObject var model: AutomaticMeasurementSessionModel
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss
    @State private var manualComparison: MeasurementSessionModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(model.snapshot.frame.source == .synthetic
                        ? "합성 연결 테스트 · 실제 ML 인식·센서 정확도 검증 아님"
                        : "동일 프레임의 측정점과 LiDAR 결과", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.bold()).foregroundStyle(model.snapshot.frame.source == .synthetic ? .orange : .teal)
                        .accessibilityIdentifier("automaticProvenance")
                    if let warning = model.recordingWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
                    AutomaticSnapshotView(snapshot: model.snapshot, image: model.image, landmarks: model.landmarks, definitions: model.definitions)
                    Text("성공한 항목은 유지하고, 미검출·깊이 부족 항목은 사유를 따로 표시합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.result.values) { value in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(value.title).font(.headline)
                                Spacer()
                                Text(value.meters.map { String(format: "%.2f cm", $0 * 100) } ?? "측정 불가")
                                    .font(.title3.monospacedDigit()).accessibilityIdentifier("automaticValue_\(value.id)")
                            }
                            Text(value.status.label).foregroundStyle(value.status == .valid ? .teal : .orange)
                            if let failure = value.failure { Text(failure.message).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                TextField("줄자 기준값", text: Binding(get: { model.references[value.id] ?? "" },
                                    set: { model.references[value.id] = $0; model.exportedURL = nil }))
                                    .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("automaticReference_\(value.id)")
                                Text("cm").foregroundStyle(.secondary)
                            }
                            if let definition = model.definitions.first(where: { $0.id == value.id }), definition.landmarkIDs.count == 2 {
                                Button("이 사진에서 수동점 검증") {
                                    // Keep model provenance until the user confirms both points.
                                    var points = model.landmarks
                                    points.points = definition.landmarkIDs.map { id in
                                        model.landmarks.points.first { $0.id == id }
                                            ?? .init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false)
                                    }
                                    let reference = Double((model.references[value.id] ?? "").replacingOccurrences(of: ",", with: "."))
                                    manualComparison = MeasurementSessionModel(snapshot: model.snapshot, landmarks: points,
                                        definition: definition, referenceCentimeters: reference,
                                        options: model.options, testContext: model.context)
                                }.font(.caption).accessibilityIdentifier("manualComparison_\(value.id)")
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
                        if let timing = model.timingText { Text(timing).font(.caption.monospacedDigit()) }
                    }.labCard()
                    Button { Task { await model.save(to: archive) } } label: {
                        Label("전체 항목 기록 저장", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.isSaving).accessibilityIdentifier("saveAutomaticMeasurement")
                    if let url = model.exportedURL {
                        Text("전체 항목을 저장했습니다").foregroundStyle(.teal).accessibilityIdentifier("automaticMeasurementSaved")
                        ShareLink("사진·깊이·전체 측정점 공유", item: url)
                    }
                    Text("계산 상태는 실제 오차 보증이 아닙니다. 실측 검증은 항목별 줄자값과 같은 조건의 독립 촬영으로 진행하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).background(Color(.systemGroupedBackground))
                .navigationTitle("자동 측정 연결 결과").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .onChange(of: model.context) { _, _ in model.exportedURL = nil }
                .sheet(item: $manualComparison) { session in MeasurementDetailView(model: session, archive: archive) }
                .alert("기록 확인", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("확인", role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }.tint(.teal)
    }
}

private struct AutomaticSnapshotView: View {
    let snapshot: CaptureSnapshot
    let image: UIImage?
    let landmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
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
                    let endpoints = definition.landmarkIDs.compactMap { id in visible.first { $0.id == id } }
                    guard endpoints.count == definition.landmarkIDs.count else { continue }
                    var path = Path()
                    for (index, endpoint) in endpoints.enumerated() {
                        if index == 0 { path.move(to: point(endpoint.point)) }
                        else { path.addLine(to: point(endpoint.point)) }
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
