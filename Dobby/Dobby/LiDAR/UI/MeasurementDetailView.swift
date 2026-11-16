import SwiftUI
import UIKit

struct MeasurementDetailView: View {
    @State private var model: ManualMeasurement
    @State private var image: UIImage?
    @State private var referenceText: String
    @State private var activePointIndex = 0
    @State private var isCalculating = false
    @State private var calculationRunID: UUID?
    @State private var isSaving = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    private let pipeline = MeasurementPipeline()
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss

    init(model: ManualMeasurement, archive: MeasurementArchive) {
        _model = State(initialValue: model)
        _referenceText = State(initialValue: model.referenceCentimeters.map { String(format: "%.2f", $0) } ?? "")
        self.archive = archive
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(model.snapshot.frame.source == .synthetic ? "합성 데이터 · 센서 정확도 검증용이 아닙니다" : "동일 프레임의 원본 사진 + LiDAR 깊이", systemImage: model.snapshot.frame.source == .synthetic ? "cube.transparent" : "checkmark.shield")
                        .font(.caption.weight(.semibold)).foregroundStyle(model.snapshot.frame.source == .synthetic ? .orange : .teal)
                    MeasurementImageView(snapshot: model.snapshot, landmarks: model.displayLandmarks, image: image,
                        activePointIndex: activePointIndex, placePoint: placePoint,
                        pointTitles: model.definition.landmarkIDs.map(GarmentPointName.title))
                        .aspectRatio(SnapshotPresentation.aspectRatio(for: model.snapshot), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text("A와 B를 차례로 누르거나 점을 끌어 위치를 바꾸세요. 옷의 경계가 사진 밖으로 잘리면 측정할 수 없습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        ForEach(Array(model.displayLandmarks.points.enumerated()), id: \.offset) { index, point in
                            Button { activePointIndex = index } label: {
                                Label("\(index == 0 ? "A" : "B") \(point.isVisible ? "지정됨" : "위치 지정")", systemImage: point.isVisible ? "checkmark.circle.fill" : "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).tint(activePointIndex == index ? .teal : .gray)
                                .accessibilityAddTraits(activePointIndex == index ? .isSelected : [])
                                .accessibilityHint("사진에서 조절할 측정점을 선택합니다")
                        }
                    }
                    Picker("옷 종류", selection: Binding(get: { model.testContext.category }, set: { selectCategory($0) })) {
                        ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("garmentCategory")
                    Picker("측정 항목", selection: Binding(get: { model.definition.id }, set: { id in
                        if let definition = model.availableDefinitions.first(where: { $0.id == id }) {
                            selectDefinition(definition)
                        }
                    })) {
                        ForEach(model.availableDefinitions) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("measurementDefinition")
                    Text(model.definition.id == "top.totalLength" && model.definition.projection != nil
                         ? "목 중앙과 밑단 중앙을 확인하세요. 이 이전 기록은 목 양끝의 3D 가로축에 수직인 총장을 사용합니다."
                         : GarmentMeasurementCatalog.guide(for: model.definition.id))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.definition.projection != nil {
                        Text("이 총장은 목 양끝의 3D 가로축을 기준으로 계산합니다. 아래에서 두 점을 직접 바꾸면 별도의 수동 직선 측정으로 전환됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    resultCard
                    if let selection = model.snapshot.selectionSummary {
                        DisclosureGroup("촬영 품질 기록") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("확인한 프레임 \(selection.observedFrameCount)장 · 선택 가능 \(selection.eligibleCandidateCount)장")
                                Text(String(format: "선택 대기 %.2f초 · 전체 화면의 유효 깊이 %.0f%%",
                                            selection.waitingDurationSeconds, selection.selectedQuality.validDepthCoverage * 100))
                                if let high = selection.selectedQuality.highConfidenceCoverage {
                                    Text(String(format: "높은 신뢰도의 깊이 %.0f%%", high * 100))
                                } else { Text("센서 신뢰도 정보 없음") }
                                Text(selection.selectedQuality.motionKnown ? "카메라 움직임 확인" : "카메라 움직임 정보 부족")
                                Text(model.snapshot.smoothedFrame == nil ? "평활화 깊이 비교 자료 없음" : "같은 촬영의 평활화 깊이 비교 자료 포함")
                                Text("전체 화면을 기준으로 선택한 기록입니다. 옷의 모든 측정점이나 실제 치수 정확도를 보증하지 않습니다.")
                                    .foregroundStyle(.secondary)
                            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.labCard().accessibilityIdentifier("captureQualityDetails")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("줄자와 비교").font(.headline)
                        HStack {
                            TextField("줄자로 잰 길이", text: $referenceText).keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("referenceCentimeters")
                                .onChange(of: referenceText) { _, _ in
                                    model.setReferenceCentimeters(parsedReference)
                                    exportedURL = nil
                                }
                            Text("cm").foregroundStyle(.secondary)
                        }
                        if let reference = model.referenceCentimeters, let meters = model.result?.values.first?.meters {
                            let error = meters * 100 - reference
                            Text(String(format: "기준 %.2f cm · 차이 %+.2f cm", reference, error))
                                .font(.subheadline.monospacedDigit()).foregroundStyle(abs(error) < 1 ? .teal : .orange)
                        }
                        TextField("옷·물체 이름 (예: 검정 셔츠 01)", text: $model.testContext.specimenName)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("testSpecimen")
                        TextField("기기 모델 (예: iPhone 17 Pro)", text: $model.testContext.deviceModel)
                            .textFieldStyle(.roundedBorder)
                        TextField("촬영 조건 (거리·기울기·소재·배경)", text: $model.testContext.conditions, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Text("같은 조건에서 새 사진을 3회 이상 촬영해 비교하세요. 같은 사진을 다시 저장한 것은 반복 촬영으로 세지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("주변 평면으로 깊이 안정화", isOn: Binding(get: { model.useLocalPlane }, set: {
                            model.setUseLocalPlane($0)
                            exportedURL = nil
                        }))
                        Text("평면에 잘 맞는 표본이 있을 때만 원래 측정점의 깊이를 보완합니다. 기울어진 평면에도 적용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Button { saveTask = Task { await save() } } label: {
                            HStack {
                                if isSaving { ProgressView().tint(.white) }
                                Label("테스트 기록 저장", systemImage: "square.and.arrow.down")
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).disabled(isSaving || isCalculating || model.result == nil)
                            .accessibilityIdentifier("saveMeasurement")
                        if let url = exportedURL {
                            Label("기록을 저장했습니다", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                                .accessibilityIdentifier("measurementSaved")
                            ShareLink(item: url) { Label("사진·깊이·측정점 JSON 공유", systemImage: "square.and.arrow.up") }
                        }
                        Text("실패한 측정도 분석용으로 저장할 수 있습니다. 원본 이미지와 깊이가 포함되며, 가져오면 현재 알고리즘으로 다시 계산합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("수동점 검증 · frame \(model.snapshot.frame.frameID.uuidString.prefix(8))")
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("측정 테스트").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .task {
                    if let decoded = await SnapshotPresentation.thumbnail(for: model.snapshot, maximumDimension: 4096),
                       !Task.isCancelled { image = decoded }
                }
                .task(id: model.calculationRevision) { await recalculate() }
                .onDisappear { saveTask?.cancel() }
                .onChange(of: model.testContext) { _, _ in exportedURL = nil }
                .alert("저장하지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("확인", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.teal)
    }

    private var parsedReference: Double? {
        guard let value = Double(referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    private func selectCategory(_ category: GarmentCategory) {
        let previousDefinition = model.definition.id
        let previousRevision = model.calculationRevision
        model.selectCategory(category)
        if previousDefinition != model.definition.id { referenceText = "" }
        if previousRevision != model.calculationRevision { activePointIndex = 0 }
        exportedURL = nil
    }

    private func selectDefinition(_ definition: MeasurementDefinition) {
        let previousDefinition = model.definition.id
        model.selectDefinition(definition)
        if previousDefinition != definition.id { referenceText = "" }
        activePointIndex = 0
        exportedURL = nil
    }

    private func placePoint(displayPoint: ImagePoint, index: Int) {
        let previousDefinition = model.definition.id
        guard model.placePoint(displayPoint: displayPoint, index: index) else { return }
        if previousDefinition != model.definition.id { referenceText = "" }
        if let next = model.displayLandmarks.points.firstIndex(where: { !$0.isVisible }) { activePointIndex = next }
        exportedURL = nil
    }

    private func recalculate() async {
        let runID = UUID()
        let revision = model.calculationRevision
        let input = model
        calculationRunID = runID
        isCalculating = true
        defer {
            if calculationRunID == runID, model.calculationRevision == revision { isCalculating = false }
        }
        // SwiftUI cancels this task on a new geometry revision or dismissal.
        // Model-level revision checks also reject an already-running stale result.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        let output = await pipeline.measure(snapshot: input.snapshot, landmarks: input.landmarks,
            definitions: [input.definition], options: input.options)
        guard !Task.isCancelled else { return }
        model.apply(output, for: revision)
    }

    private func save() async {
        guard !isSaving, !isCalculating, model.result != nil else { return }
        guard referenceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedReference != nil else {
            errorMessage = "줄자 기준값은 0보다 큰 숫자로 입력하거나 비워 주세요."
            return
        }
        model.setReferenceCentimeters(parsedReference)
        isSaving = true
        let revision = model.persistenceRevision
        let savedReferenceText = referenceText
        defer { isSaving = false }
        do {
            let record = try model.makeRecord()
            let url = try await archive.save(record)
            guard !Task.isCancelled, model.persistenceRevision == revision,
                  referenceText == savedReferenceText else { return }
            exportedURL = url
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func samplingLabel(_ method: DepthSamplingMethod) -> String {
        switch method {
        case .localPlane: "국소 평면"
        case .robustMedian: "주변 중앙값"
        case .spatialAverage: "원본 측정점의 3D 평균"
        case .recoveredSpatialAverage: "깊이를 복구한 측정점의 3D 평균"
        case .axisProjection: "의류 가로축의 직교 방향"
        case .garmentPlane: "옷 대표 평면"
        case .contourIntersection: "대표 평면의 총장 윤곽 교점"
        }
    }

    @ViewBuilder private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.definition.title).font(.headline)
            if isCalculating {
                ProgressView("측정 중…")
            } else if let value = model.result?.values.first {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.hasUsableMeasurement ? value.meters.map { MeasurementDisplayText.centimeters($0 * 100) } ?? "—" : "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                        .accessibilityIdentifier("measurementValue")
                    Text("cm").font(.title2).foregroundStyle(.secondary)
                    Spacer()
                    Text(value.hasUsableMeasurement ? "계산 완료" : "측정 불가").font(.caption.bold()).padding(8)
                        .background(value.hasUsableMeasurement ? Color.teal.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                }
                MeasurementFailureFeedbackView(value: value)
                ForEach(Array(value.points.enumerated()), id: \.offset) { index, point in
                    HStack {
                        Text(point.id == model.definition.landmarkIDs.first ? "A" : "B").fontWeight(.semibold)
                        Text(String(format: "깊이 %.3f m", point.position.z))
                        Spacer()
                        Text("표본 \(point.quality.validSamples)/\(point.quality.candidateSamples)")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(samplingLabel(point.quality.method)) · 신뢰도 \(point.quality.confidenceAvailable ? "수신" : "없음")" + (point.quality.planeResidualMeters.map { String(format: " · 평면 잔차 %.1f mm", $0 * 1000) } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let plane = point.quality.garmentPlaneQuality {
                        Text(String(format: "대표 평면 직교 RMS %.1f mm · 지지 표본 %d/%d",
                                    plane.orthogonalRMSMeters * 1000, plane.inlierCount, plane.candidateCount))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }.labCard()
    }
}

struct MeasurementImageView: View {
    let snapshot: CaptureSnapshot
    let landmarks: GarmentLandmarkSet
    let image: UIImage?
    let activePointIndex: Int
    let placePoint: (ImagePoint, Int) -> Void
    var pendingPointIDs: Set<String> = []
    var pointTitles: [String] = []
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image { Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true) }
                else { Color.gray.opacity(0.2) }
                Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { event in
                    placePoint(normalized(event.location, size: geometry.size), activePointIndex)
                })
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits([.isImage, .isButton])
                .accessibilityLabel("선택한 측정점 \(activePointIndex == 0 ? "A" : "B")의 위치를 지정할 사진")
                .accessibilityHint("두 번 탭하면 선택한 점을 사진 중앙에 놓습니다. 각 측정점의 방향 동작으로 위치를 조절할 수 있어요")
                .accessibilityAction {
                    confirmAccessiblePoint(.init(x: 0.5, y: 0.5), index: activePointIndex)
                }
                .accessibilityIdentifier("measurementEditorPhoto")
                Canvas { context, size in
                    let visible = landmarks.points.filter { $0.isVisible && !pendingPointIDs.contains($0.id) }
                    if visible.count == 2 {
                        let a = screen(visible[0].point, size: size), b = screen(visible[1].point, size: size)
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 5)
                        context.stroke(path, with: .color(.yellow), style: .init(lineWidth: 2, dash: [7, 4]))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                ForEach(Array(landmarks.points.enumerated()), id: \.offset) { index, point in
                    if point.isVisible {
                        Text(index == 0 ? "A" : "B").font(.caption.bold()).foregroundStyle(.black)
                            .frame(width: 32, height: 32)
                            .background(pendingPointIDs.contains(point.id) ? GarmentCaptureStyle.accent : .yellow, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 3).padding(8).contentShape(Circle())
                            .position(screen(point.point, size: geometry.size))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("measurementImage")).onChanged { value in
                                placePoint(normalized(value.location, size: geometry.size), index)
                            })
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAddTraits(activePointIndex == index ? .isSelected : [])
                            .accessibilityLabel(accessiblePointName(point, index: index))
                            .accessibilityValue("\(pendingPointIDs.contains(point.id) ? "위치 확인 필요" : "위치 지정됨"). \(MeasurementPointAccessibilityText.position(displayPoint(point)))")
                            .accessibilityHint("두 번 탭하면 현재 위치를 확정합니다. \(MeasurementPointAccessibilityText.movementHint)")
                            .accessibilityAction { confirmAccessiblePoint(displayPoint(point), index: index) }
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: nudge(point, index: index, dx: 2, dy: 0, size: geometry.size)
                                case .decrement: nudge(point, index: index, dx: -2, dy: 0, size: geometry.size)
                                @unknown default: break
                                }
                            }
                            .accessibilityAction(named: "왼쪽으로 이동") { nudge(point, index: index, dx: -2, dy: 0, size: geometry.size) }
                            .accessibilityAction(named: "오른쪽으로 이동") { nudge(point, index: index, dx: 2, dy: 0, size: geometry.size) }
                            .accessibilityAction(named: "위로 이동") { nudge(point, index: index, dx: 0, dy: -2, size: geometry.size) }
                            .accessibilityAction(named: "아래로 이동") { nudge(point, index: index, dx: 0, dy: 2, size: geometry.size) }
                            .accessibilityIdentifier("measurementEditorPoint_\(point.id)")
                    }
                }
            }.coordinateSpace(name: "measurementImage").clipped()
        }
    }
    private func normalized(_ p: CGPoint, size: CGSize) -> ImagePoint {
        .init(x: min(0.999999, max(0, p.x / max(1, size.width))), y: min(0.999999, max(0, p.y / max(1, size.height))))
    }
    private func screen(_ p: ImagePoint, size: CGSize) -> CGPoint {
        let display = ImageCoordinateTransform.originalToDisplay(p, orientation: snapshot.frame.orientation)
        return CGPoint(x: display.x * size.width, y: display.y * size.height)
    }

    private func displayPoint(_ point: GarmentLandmark) -> ImagePoint {
        ImageCoordinateTransform.originalToDisplay(point.point, orientation: snapshot.frame.orientation)
    }

    private func accessiblePointName(_ point: GarmentLandmark, index: Int) -> String {
        let title = pointTitles.indices.contains(index) ? pointTitles[index] : GarmentPointName.title(point.id)
        return "측정점 \(index == 0 ? "A" : "B"), \(title)"
    }

    private func confirmAccessiblePoint(_ display: ImagePoint, index: Int) {
        guard image != nil, scenePhase == .active, landmarks.points.indices.contains(index),
              display.x.isFinite, display.y.isFinite else { return }
        let bounded = ImagePoint(x: min(0.999999, max(0, display.x)), y: min(0.999999, max(0, display.y)))
        placePoint(bounded, index)
        VoiceOverAnnouncement.post("측정점 \(index == 0 ? "A" : "B") 위치 확인. \(MeasurementPointAccessibilityText.position(bounded))")
    }

    private func nudge(_ point: GarmentLandmark, index: Int, dx: CGFloat, dy: CGFloat, size: CGSize) {
        guard image != nil, scenePhase == .active, size.width > 0, size.height > 0 else { return }
        let current = screen(point.point, size: size)
        let next = normalized(CGPoint(x: current.x + dx, y: current.y + dy), size: size)
        guard next != displayPoint(point) else { VoiceOverAnnouncement.post("사진 가장자리예요"); return }
        placePoint(next, index)
        VoiceOverAnnouncement.post("\(accessiblePointName(point, index: index)), \(MeasurementPointAccessibilityText.direction(dx: dx, dy: dy)). \(MeasurementPointAccessibilityText.position(next))")
    }
}

extension MeasurementStatus {
    var label: String { switch self { case .valid: "계산 완료"; case .uncertain: "확인 필요"; case .unavailable: "측정 불가" } }
}

extension MeasurementFailure {
    var message: String { fallbackExplanation }
}
