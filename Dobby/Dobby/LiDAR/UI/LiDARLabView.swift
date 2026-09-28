import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LiDARLabView: View {
    @StateObject private var capture: ARKitCaptureProvider
    @StateObject private var automatic: AutomaticMeasurementViewModel
    @State private var showCamera = false
    @State private var showReadinessDemo = false
    @State private var showBaseline = false
    @State private var showValidation = false
    @State private var automaticMode = false
    @State private var automaticSession: AutomaticMeasurementSessionModel?
    @State private var session: MeasurementSessionModel?
    @State private var records: [MeasurementSummary] = []
    @State private var demo: DemoScenario = .flat
    @State private var showImporter = false
    @State private var errorMessage: String?
    private let archive = MeasurementArchive()

    init(landmarkProvider: (any GarmentLandmarkProviding)? = nil) {
        let camera = ARKitCaptureProvider()
        _capture = StateObject(wrappedValue: camera)
        _automatic = StateObject(wrappedValue: AutomaticMeasurementViewModel(camera: camera, provider: landmarkProvider))
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
                        Text("이 화면은 거리 엔진 검증용입니다. 의류 측정점 자동 검출은 ML 모듈이 연결되면 같은 엔진을 사용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("자동 측정 연결", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                        Text(automatic.hasModel ? "촬영한 한 프레임에서 측정점과 모든 항목의 치수를 계산합니다."
                             : "의류 ML 모델 연결 대기 중입니다. 아래 합성 테스트로 촬영→측정점 수신→치수 계산·부분 실패·저장을 확인할 수 있습니다.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { automaticMode = true; showCamera = true } label: {
                            Label("ML 자동 측정 촬영", systemImage: "camera.badge.ellipsis").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(!automatic.hasModel || !capture.isSupported || automatic.isRunning)
                        Button {
                            Task {
                                await automatic.runDemo()
                                if let value = automatic.session { automaticSession = value }
                            }
                        } label: { Label("합성 자동 연결 테스트", systemImage: "play.rectangle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).disabled(automatic.isRunning).accessibilityIdentifier("openAutomaticDemo")
                        if automatic.isRunning {
                            ProgressView(automatic.phaseLabel)
                            Button("자동 측정 취소") { automatic.cancel() }
                        }
                        if let message = automatic.errorMessage { Text(message).font(.caption).foregroundStyle(.orange) }
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
                            session = MeasurementSessionModel(snapshot: value.snapshot, landmarks: value.landmarks, expectedMeters: value.expected)
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
                .sheet(isPresented: $showBaseline) { BaselineReportView(archive: archive) }
                .sheet(isPresented: $showValidation) { MeasurementValidationReportView(archive: archive) }
                .sheet(item: $automaticSession, onDismiss: { Task { await refreshRecords() } }) { model in
                    AutomaticMeasurementResultView(model: model, archive: archive)
                }
                .sheet(isPresented: $showReadinessDemo) { LiveReadinessDemoView() }
                .sheet(item: $session, onDismiss: { Task { await refreshRecords() } }) { model in
                    MeasurementDetailView(model: model, archive: archive)
                }
                .fullScreenCover(isPresented: $showCamera, onDismiss: {
                    if let snapshot = pendingSnapshot {
                        pendingSnapshot = nil
                        if automaticMode { automaticSession = automatic.session }
                        else { session = MeasurementSessionModel(snapshot: snapshot) }
                    }
                }) {
                    LiDARCameraView(provider: capture, onCapture: { snapshot in
                        pendingSnapshot = snapshot
                        showCamera = false
                    }, captureAction: automaticMode ? { try await automatic.runLive(orientation: $0) } : nil,
                       progressText: automaticMode ? automatic.phaseLabel : nil)
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
            let value = AutomaticMeasurementSessionModel(record: record)
            await value.replay()
            automaticSession = value
            return
        }
        guard definition.landmarkIDs.count == 2 else { throw ArchiveError.invalidFile }
        var selectedPoints = record.landmarks
        selectedPoints.points = definition.landmarkIDs.map { id in
            record.landmarks.points.first(where: { $0.id == id }) ?? .init(id: id, point: .init(x: 0.5, y: 0.5), confidence: nil, isVisible: false)
        }
        let model = MeasurementSessionModel(snapshot: record.snapshot, landmarks: selectedPoints,
            definition: definition, referenceCentimeters: record.referenceCentimeters, options: record.options, testContext: record.testContext)
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
