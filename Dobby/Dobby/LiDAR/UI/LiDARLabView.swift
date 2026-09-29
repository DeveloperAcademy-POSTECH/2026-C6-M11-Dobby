import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LiDARLabView: View {
    private let bottomProvider: CoreMLBottomLandmarkProvider?
    private let bottomModelLoadError: String?
    private let usesBottomModel: Bool
    @State private var showBottomRecognition = false
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

    init(landmarkProvider: (any GarmentLandmarkProviding)? = nil) {
        let bundled: CoreMLBottomLandmarkProvider?
        let loadingError: String?
        do {
            bundled = try CoreMLBottomLandmarkProvider.bundled()
            loadingError = nil
        } catch {
            bundled = nil
            loadingError = error.localizedDescription
        }
        self.bottomProvider = bundled
        self.bottomModelLoadError = loadingError
        self.usesBottomModel = landmarkProvider == nil && bundled != nil
        let provider: (any GarmentLandmarkProviding)? = landmarkProvider ?? bundled
        let definitions = landmarkProvider == nil ? (bundled?.schema.measurementDefinitions ?? []) : MeasurementDefinition.longSleeve
        let camera = ARKitCaptureProvider()
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
                        Text("수동 촬영은 두 점을 직접 지정합니다. 아래 하의 자동 측정에서는 모델이 바지·반바지의 측정점을 찾습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label(usesBottomModel ? "하의 자동 인식 · LiDAR 측정" : "자동 측정 연결", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                        Text((automaticService != nil) ? (usesBottomModel ? "바지·반바지 한 벌을 허리는 위, 밑단은 아래로 펼쳐 촬영하세요. 허리·가랑이·양쪽 밑단을 찾아 같은 프레임의 LiDAR 깊이로 직선 치수를 계산합니다." : "촬영한 한 프레임에서 측정점과 모든 항목의 치수를 계산합니다.")
                             : "의류 ML 모델 연결 대기 중입니다. 아래 합성 테스트로 촬영→측정점 수신→치수 계산·부분 실패·저장을 확인할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { automaticMode = true; showCamera = true } label: {
                            Label(usesBottomModel ? "하의 자동 측정 촬영" : "ML 자동 측정 촬영", systemImage: "camera.badge.ellipsis").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(!(automaticService != nil) || !capture.isSupported || isAutomaticRunning)
                            .accessibilityIdentifier("startBottomAutomaticCapture")
                        if bottomProvider != nil {
                            Button { showBottomRecognition = true } label: {
                                Label("하의 사진으로 인식 테스트", systemImage: "photo.badge.magnifyingglass").frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).accessibilityIdentifier("openBottomRecognition")
                            Text("사진 테스트는 점의 위치만 보여줍니다. cm 측정은 LiDAR 촬영에서 가능합니다. 치마·상의는 이 모델의 대상이 아닙니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let bottomModelLoadError {
                            Text(bottomModelLoadError).font(.caption).foregroundStyle(.orange)
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
                .onDisappear { if !showCamera { cancelAutomatic() } }
                .sheet(isPresented: $showBottomRecognition) {
                    if let bottomProvider { BottomRecognitionView(provider: bottomProvider) }
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
                                context: .init(category: usesBottomModel ? .bottoms : .top, deviceModel: SnapshotPresentation.deviceIdentifier))
                        } else if !automaticMode {
                            session = ManualMeasurement(snapshot: snapshot,
                                testContext: .init(deviceModel: SnapshotPresentation.deviceIdentifier))
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
                    if !synthetic, phase == .detectingLandmarks { capture.stop() }
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
            let replayed = await MeasurementPipeline().measure(snapshot: value.snapshot, landmarks: value.landmarks,
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
