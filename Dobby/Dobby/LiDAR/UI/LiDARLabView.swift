import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LiDARLabView: View {
    private let landmarkProvider: (any GarmentLandmarkProviding)?

    init(landmarkProvider: (any GarmentLandmarkProviding)? = nil) {
        self.landmarkProvider = landmarkProvider
    }

    var body: some View {
        LiDARLabContent(landmarkProvider: landmarkProvider)
    }
}

private struct LiDARLabContent: View {
    private let modelLoadError: String?
    private let usesBundledModel: Bool
    @State private var photoDiagnostic: GarmentPhotoDiagnostic?
    @State private var garmentFlow: GarmentFlowDestination?
    @StateObject private var capture: ARKitCaptureProvider
    @State private var automaticService: RecordedMeasurementService?
    @State private var demoService: RecordedMeasurementService
    @State private var automaticPhase: AutomaticMeasurementPhase = .idle
    @State private var isAutomaticRunning = false
    @State private var automaticError: String?
    @State private var automaticRunID: UUID?
    @State private var automaticTask: Task<Void, Never>?
    @State private var pendingAutomaticOutput: RecordedMeasurementOutput?
    @State private var automaticRecordingError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCamera = false
    @State private var showReadinessDemo = false
    @State private var showBaseline = false
    @State private var showValidation = false
    @State private var automaticMode = false
    @State private var automaticSession: AutomaticMeasurement?
    @State private var session: ManualMeasurement?
    @State private var records: [MeasurementSummary] = []
    @State private var demo: DemoScenario = .flat
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var archive = MeasurementArchive()

    init(landmarkProvider: (any GarmentLandmarkProviding)?) {
        let bundled: AutoGarmentLandmarkProvider?
        let loadingError: String?
        do {
            bundled = try AutoGarmentLandmarkProvider.bundled()
            loadingError = nil
        } catch {
            bundled = nil
            loadingError = error.localizedDescription
        }
        self.modelLoadError = loadingError
        self.usesBundledModel = landmarkProvider == nil
        let provider: (any GarmentLandmarkProviding)? = landmarkProvider ?? bundled
        let definitions = landmarkProvider == nil ? [] : MeasurementDefinition.longSleeve
        let recognizer: (any GarmentImageRecognizing)? = landmarkProvider == nil
            ? bundled : landmarkProvider as? any GarmentImageRecognizing
        let camera = ARKitCaptureProvider(garmentRecognizer: recognizer)
        _capture = StateObject(wrappedValue: camera)
        let journal = LiDARAppServices.attemptJournal
        _automaticService = State(initialValue: provider.map { provider in
            RecordedMeasurementService(workflow: AutomaticMeasurementWorkflow(camera: camera,
                landmarks: provider, definitions: definitions,
                expectedLandmarkOrigin: .model), journal: journal)
        })
        _demoService = State(initialValue: RecordedMeasurementService(workflow: AutomaticMeasurementWorkflow(
            camera: IntegrationDemoCamera(), landmarks: IntegrationDemoLandmarks(),
            definitions: IntegrationDemoLandmarks.definitions, expectedLandmarkOrigin: .synthetic), journal: journal))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("DOBBY · LiDAR", systemImage: "viewfinder").font(.caption.weight(.semibold)).foregroundStyle(.teal)
                        Text("길이를 확인하는\n가장 직접적인 방법").font(.largeTitle.bold())
                        Text("사진 속 두 점을 실제 공간의 위치로 복원해 길이를 계산합니다.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("옷을 찍고, 실측을 확인하세요").font(.title3.bold())
                        Text("옷 모양의 윤곽을 확인한 뒤 촬영하면 사진 위에 실측값이 표시됩니다. 긴팔·반팔 상의와 바지·반바지를 지원합니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("카메라가 상의·하의를 자동으로 구분합니다. 한 벌을 바닥에 평평하게 펼치고 소매와 밑단까지 모두 보여주세요.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("automaticGarmentRecognitionHelp")
                        Button { garmentFlow = .live } label: {
                            Label("실측 촬영", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).tint(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("openGarmentCapture")
                        Button("촬영 화면 미리보기") { garmentFlow = .preview }
                            .font(.subheadline).accessibilityIdentifier("openGarmentPreview")
                        Text("미리보기는 합성 화면이며 실제 옷 인식·센서 측정이 아닙니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()
                    VStack(alignment: .leading, spacing: 14) {
                        Label("실제 기기로 측정", systemImage: "camera.fill").font(.headline)
                        Text(capture.isSupported ? "옷을 펼친 뒤 전체가 보이게 촬영하세요. 테스트 화면에서 두 점과 줄자 기준값을 지정할 수 있습니다." : "현재 기기에서는 LiDAR 촬영을 사용할 수 없습니다. 아래 데모로 계산과 저장을 테스트할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { automaticMode = false; showCamera = true } label: {
                            Label("LiDAR 촬영 시작", systemImage: "camera.viewfinder").frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).tint(.teal).disabled(!capture.isSupported)
                            .accessibilityIdentifier("startLiDARCapture")
                        Button { showReadinessDemo = true } label: {
                            Label("실시간 안내 미리보기", systemImage: "viewfinder.circle").frame(maxWidth: .infinity)
                        }.buttonStyle(.bordered).accessibilityIdentifier("openReadinessDemo")
                        Text("수동 촬영은 두 점을 직접 지정합니다. 자동 측정에서는 촬영한 옷의 종류와 측정점을 함께 확인합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label(usesBundledModel ? "상·하의 자동 인식 · LiDAR 측정" : "자동 측정 연결", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                        Text((automaticService != nil) ? (usesBundledModel ? automaticModelDescription : "촬영한 한 프레임에서 측정점과 모든 항목의 치수를 계산합니다.")
                             : "의류 ML 모델 연결 대기 중입니다. 아래 합성 테스트로 촬영→측정점 수신→치수 계산·부분 실패·저장을 확인할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { automaticMode = true; showCamera = true } label: {
                            Label(usesBundledModel ? "옷 자동 측정 촬영" : "ML 자동 측정 촬영", systemImage: "camera.badge.ellipsis").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(!(automaticService != nil) || !capture.isSupported || isAutomaticRunning)
                            .accessibilityIdentifier("startAutomaticCapture")
                        if let modelLoadError {
                            Text(modelLoadError).font(.caption).foregroundStyle(.orange)
                        }
                        Button {
                            automaticTask = Task {
                                do { _ = try await runAutomatic(using: demoService, orientation: .up, synthetic: true) }
                                catch is CancellationError { }
                                catch {
                                    if (error as? any AutomaticMeasurementFailureClassifying)?.automaticMeasurementFailureCode != .cancelled {
                                        automaticError = error.localizedDescription
                                    }
                                }
                            }
                        } label: { Label("합성 자동 연결 테스트", systemImage: "play.rectangle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(isAutomaticRunning).accessibilityIdentifier("openAutomaticDemo")
                        if isAutomaticRunning {
                            ProgressView(automaticPhaseLabel)
                            Button("자동 측정 취소") { cancelAutomatic() }
                        }
                        if let message = automaticError { Text(message).font(.caption).foregroundStyle(.orange) }
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("모델별 사진 진단", systemImage: "photo.badge.magnifyingglass").font(.headline)
                        Text("이 선택은 개별 모델의 점 인식을 확인하는 진단용입니다. 실측 촬영에서는 옷 종류를 자동으로 구분합니다. 사진 진단은 cm 치수를 계산하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(AutomaticGarmentKind.allCases) { kind in
                            Button { openPhotoDiagnostic(kind) } label: {
                                Label("\(kind.title) 사진 인식 진단", systemImage: "photo").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered)
                                .accessibilityIdentifier(kind == .top ? "openTopRecognition" : "openBottomRecognition")
                        }
                    }.labCard()

                    VStack(alignment: .leading, spacing: 14) {
                        Label("50cm 데모 실험", systemImage: "ruler").font(.headline)
                        Text("정답 길이를 아는 합성 깊이 데이터입니다. 실제 센서 정확도를 의미하지 않습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Picker("데모 조건", selection: $demo) {
                            ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        Button {
                            let value = DemoSnapshotFactory.make(demo)
                            session = ManualMeasurement(snapshot: value.snapshot, landmarks: value.landmarks,
                                expectedMeters: value.expected, testContext: .init(deviceModel: SnapshotPresentation.deviceIdentifier))
                        } label: { Label("데모 테스트 열기", systemImage: "play.circle.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).accessibilityIdentifier("openDemo")
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("실측 검증").font(.title3.bold())
                            Spacer()
                            Button { showBaseline = true } label: { Label("비교 보고서", systemImage: "chart.bar.doc.horizontal") }
                                .accessibilityIdentifier("openBaselineReport")
                        }
                        Text("저장한 실촬영 기록으로 기본 계산과 깊이 안정화의 오차·실패율을 비교합니다. 합성 데모는 실측 통계에서 제외합니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { showValidation = true } label: { Label("최종 검증 · 시도 기록", systemImage: "checklist") }
                            .accessibilityIdentifier("openValidationReport")
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("저장한 테스트").font(.title3.bold())
                            Spacer()
                            Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
                                .accessibilityLabel("측정 JSON 가져오기")
                        }
                        if records.isEmpty {
                            Text("촬영 이미지·깊이·측정점을 저장하면 같은 데이터로 다시 계산할 수 있습니다.")
                                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
                        }
                        ForEach(records) { record in
                            Button {
                                Task {
                                    do { try await openRecord(archive.load(record.id)) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: record.source == .synthetic ? "cube.transparent" : "camera.metering.center.weighted")
                                        .font(.title2).foregroundStyle(.teal).frame(width: 36)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title + (record.source == .synthetic ? " · 데모" : " · LiDAR")).font(.subheadline.bold())
                                        Text(record.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(record.centimeters.map { String(format: "%.1f cm", $0) } ?? "측정 불가").monospacedDigit()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.labCard()
                }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("측정 실험실").navigationBarTitleDisplayMode(.inline)
                .task { await refreshRecords() }
                .onChange(of: scenePhase) { _, phase in if phase != .active { cancelAutomatic() } }
                .onDisappear { if !showCamera { cancelAutomatic(); capture.stop() } }
                .sheet(item: $photoDiagnostic) { diagnostic in
                    GarmentRecognitionView(provider: diagnostic.provider)
                }
                .fullScreenCover(item: $garmentFlow, onDismiss: { Task { await refreshRecords() } }) { destination in
                    GarmentCaptureFlowView(archive: archive, preview: destination == .preview)
                }
                .sheet(isPresented: $showBaseline) { BaselineReportView(archive: archive) }
                .sheet(isPresented: $showValidation) { MeasurementValidationReportView(archive: archive) }
                .sheet(item: $automaticSession, onDismiss: { Task { await refreshRecords() } }) { model in
                    AutomaticMeasurementResultView(model: model, archive: archive, recordingError: automaticRecordingError)
                }
                .sheet(isPresented: $showReadinessDemo) { LiveReadinessDemoView() }
                .sheet(item: $session, onDismiss: { Task { await refreshRecords() } }) { model in
                    MeasurementDetailView(model: model, archive: archive)
                }
                .fullScreenCover(isPresented: $showCamera, onDismiss: {
                    if let snapshot = pendingSnapshot {
                        pendingSnapshot = nil
                        if automaticMode, let completed = pendingAutomaticOutput {
                            pendingAutomaticOutput = nil
                            automaticRecordingError = completed.recordingError
                            automaticSession = AutomaticMeasurement(output: completed.workflowOutput,
                                context: .init(category: completed.workflowOutput.landmarks.garmentKind?.category ?? .other,
                                               deviceModel: SnapshotPresentation.deviceIdentifier))
                        } else if !automaticMode {
                            session = ManualMeasurement(snapshot: snapshot,
                                testContext: .init(category: .other, deviceModel: SnapshotPresentation.deviceIdentifier))
                        }
                    }
                }) {
                    LiDARCameraView(provider: capture, onCapture: { snapshot in
                        pendingSnapshot = snapshot
                        showCamera = false
                    }, captureAction: automaticMode ? { orientation in
                        guard let automaticService else { throw ArchiveError.invalidFile }
                        return try await runAutomatic(using: automaticService, orientation: orientation, synthetic: false)
                    } : nil,
                       progressText: automaticMode ? automaticPhaseLabel : nil)
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                    Task {
                        do {
                            let url = try result.get()
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            try await openRecord(archive.importRecord(from: url))
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .alert("확인해 주세요", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("확인", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.teal)
    }

    // These are presentation tasks and transient UI states. Domain execution and
    // durable attempt logging remain in the injected, non-observable service.
    private var automaticModelDescription: String {
        "같은 촬영 사진에서 상의·하의를 구분하고 해당 옷의 측정점을 찾습니다. 긴팔·반팔 상의와 바지·반바지를 지원합니다. 종류를 확실히 구분하지 못하면 촬영 안내를 다시 확인해 주세요. 결과의 점과 치수는 눈으로 확인하고 줄자와 비교해 주세요."
    }

    private func openPhotoDiagnostic(_ kind: AutomaticGarmentKind) {
        do {
            photoDiagnostic = .init(provider: try CoreMLGarmentLandmarkProvider.bundled(kind: kind))
        } catch { errorMessage = error.localizedDescription }
    }

    private var automaticPhaseLabel: String {
        switch automaticPhase {
        case .idle: "촬영 준비"
        case .capturing: "사진과 깊이를 고정하는 중…"
        case .detectingLandmarks: "같은 사진에서 측정점을 받는 중…"
        case .measuring: "측정점의 실제 길이를 계산하는 중…"
        case .completed: "계산 완료"
        case .failed: "자동 측정 실패"
        case .cancelled: "자동 측정 취소"
        }
    }

    private func cancelAutomatic() {
        guard isAutomaticRunning else { return }
        automaticRunID = nil
        automaticTask?.cancel()
        automaticService?.cancel()
        demoService.cancel()
        pendingAutomaticOutput = nil
        automaticPhase = .cancelled
    }

    private func runAutomatic(using service: RecordedMeasurementService, orientation: ImageOrientation,
                              synthetic: Bool) async throws -> CaptureSnapshot {
        guard !isAutomaticRunning else { throw CancellationError() }
        let token = UUID()
        automaticRunID = token
        isAutomaticRunning = true
        automaticError = nil
        automaticPhase = .capturing
        pendingAutomaticOutput = nil
        defer {
            isAutomaticRunning = false
            if automaticRunID == token { automaticRunID = nil }
        }
        do {
            let completed = try await service.run(orientation: orientation,
                purpose: synthetic ? .fixture : .automaticModel, isSynthetic: synthetic,
                deviceContext: synthetic ? "Synthetic integration fixture" : SnapshotPresentation.deviceIdentifier,
                onPhaseChange: { phase in
                    guard automaticRunID == token else { return }
                    automaticPhase = phase
                    if !synthetic, phase == .detectingLandmarks { capture.pauseForMeasurement() }
                })
            guard automaticRunID == token, !Task.isCancelled else { throw CancellationError() }
            if synthetic {
                automaticRecordingError = completed.recordingError
                automaticSession = AutomaticMeasurement(output: completed.workflowOutput,
                    context: .init(deviceModel: "Synthetic fixture"))
            } else { pendingAutomaticOutput = completed }
            return completed.workflowOutput.snapshot
        } catch {
            if automaticRunID != token || Task.isCancelled { throw CancellationError() }
            let cancelled = (error as? any AutomaticMeasurementFailureClassifying)?.automaticMeasurementFailureCode == .cancelled
            automaticPhase = cancelled ? .cancelled : .failed
            throw error
        }
    }

    @State private var pendingSnapshot: CaptureSnapshot?

    private func refreshRecords() async {
        do { records = try await archive.summaries() }
        catch { errorMessage = error.localizedDescription }
    }

    private func openRecord(_ record: SavedMeasurement) async throws {
        guard let image = UIImage(data: record.snapshot.imageJPEG), let cg = image.cgImage,
              cg.width == record.snapshot.frame.imageSize.width,
              cg.height == record.snapshot.frame.imageSize.height,
              let definition = record.definitions.first,
              Set(record.definitions.map(\.id)).count == record.definitions.count,
              Set(record.landmarks.points.map(\.id)).count == record.landmarks.points.count else {
            throw ArchiveError.invalidFile
        }
        if record.definitions.count > 1 || record.landmarks.origin == .model {
            var value = AutomaticMeasurement(record: record)
            let replayed = await MeasurementPipeline().measure(snapshot: value.snapshot, landmarks: value.calculationLandmarks,
                definitions: value.definitions, options: value.options)
            guard value.apply(replayed), !Task.isCancelled else { throw ArchiveError.invalidFile }
            automaticRecordingError = nil
            automaticSession = value
            return
        }
        guard definition.landmarkIDs.count == 2 else { throw ArchiveError.invalidFile }
        var selectedPoints = record.landmarks
        selectedPoints.points = definition.landmarkIDs.map { id in
            record.landmarks.points.first(where: { $0.id == id }) ?? .init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false)
        }
        let model = ManualMeasurement(snapshot: record.snapshot, landmarks: selectedPoints,
            definition: definition, referenceCentimeters: record.referenceCentimeters, options: record.options,
            testContext: record.testContext ?? .init(deviceModel: SnapshotPresentation.deviceIdentifier))
        session = model
    }
}

private enum GarmentFlowDestination: String, Identifiable {
    case live, preview
    var id: String { rawValue }
}

private struct GarmentPhotoDiagnostic: Identifiable {
    let provider: CoreMLGarmentLandmarkProvider
    var id: String { provider.kind.id }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case flat, tilted, noisy, missing
    var id: String { rawValue }
    var title: String {
        switch self { case .flat: "평면"; case .tilted: "기울기"; case .noisy: "잡음"; case .missing: "깊이 결손" }
    }
}

@MainActor
enum DemoSnapshotFactory {
    static func make(_ scenario: DemoScenario) -> (snapshot: CaptureSnapshot, landmarks: GarmentLandmarkSet, expected: Double) {
        let value = SyntheticFixtures.scene(tilted: scenario == .tilted, noisy: scenario == .noisy, missingDepth: scenario == .missing)
        let size = CGSize(width: value.frame.imageSize.width, height: value.frame.imageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor(red: 0.88, green: 0.91, blue: 0.90, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.65).cgColor)
            cg.setLineWidth(1)
            for x in stride(from: 0, through: Int(size.width), by: 40) {
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: Int(size.height)))
            }
            for y in stride(from: 0, through: Int(size.height), by: 40) {
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: Int(size.width), y: y))
            }
            cg.strokePath()
            let points = value.landmarks.points.map { CGPoint(x: $0.point.x * size.width, y: $0.point.y * size.height) }
            if points.count >= 2 {
                let a = points[0], b = points[1]
                let path = UIBezierPath(roundedRect: CGRect(x: min(a.x, b.x), y: a.y - 52, width: abs(b.x-a.x), height: 104), cornerRadius: 12)
                UIColor(red: 0.13, green: 0.29, blue: 0.27, alpha: 1).setFill(); path.fill()
                for index in 0...10 {
                    let x = a.x + (b.x-a.x) * CGFloat(index) / 10
                    cg.move(to: CGPoint(x: x, y: a.y - 42)); cg.addLine(to: CGPoint(x: x, y: a.y - 22))
                }
                cg.setLineWidth(2); cg.setStrokeColor(UIColor.white.cgColor); cg.strokePath()
            }
            let text = "50 cm · SYNTHETIC DEPTH"
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: UIColor.darkGray]
            (text as NSString).draw(at: CGPoint(x: 36, y: 35), withAttributes: attributes)
            ("\(scenario.title) — 센서 촬영 이미지가 아닙니다" as NSString).draw(at: CGPoint(x: 36, y: size.height - 65), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.darkGray])
        }
        return (.init(frame: value.frame, imageJPEG: image.jpegData(compressionQuality: 0.92) ?? Data()), value.landmarks, value.expectedMeters)
    }
}

extension View {
    func labCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}
