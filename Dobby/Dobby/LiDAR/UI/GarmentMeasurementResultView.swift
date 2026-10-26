import SwiftUI
import UIKit

/// Direct edits recalculate from the same frozen capture and preserve the
/// original automatic observation alongside the corrected result.
struct GarmentMeasurementResultView: View {
    @State private var model: AutomaticMeasurement
    let archive: MeasurementArchive
    let recordingError: String?
    let onRetake: () -> Void
    let onConfirm: () -> Void
    let onConfirmedRecord: ((SavedMeasurement) async throws -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("dobby.measurementResult.pointTutorial.v1.seen") private var hasSeenPointTutorial = false
    @State private var image: UIImage?
    @State private var selectedDefinition: MeasurementDefinition?
    @State private var showPhoto = false
    @State private var showDetails = false
    @State private var showAuxiliaryDetails = false
    @State private var detailDefinition: MeasurementDefinition?
    @State private var detailManualReview: ManualMeasurement?
    @State private var totalLengthCorrection: ManualMeasurement?
    @State private var detailTotalLengthCorrection: ManualMeasurement?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var manualReview: ManualMeasurement?
    @State private var isEditingPoint = false
    @State private var calculationRunID: UUID?
    @State private var pendingRecord: SavedMeasurement?
    @State private var pendingRecordRevision: UUID?
    @State private var pendingRecordArchived = false
    @State private var showsPointTutorial = false
    @State private var hasPresentedPointTutorial = false
    private let pipeline = MeasurementPipeline()

    init(model: AutomaticMeasurement, archive: MeasurementArchive,
         recordingError: String? = nil, initialImage: UIImage? = nil, onRetake: @escaping () -> Void,
         onConfirm: @escaping () -> Void,
         onConfirmedRecord: ((SavedMeasurement) async throws -> Void)? = nil) {
        _model = State(initialValue: model)
        self.archive = archive
        self.recordingError = recordingError
        self.onRetake = onRetake
        self.onConfirm = onConfirm
        self.onConfirmedRecord = onConfirmedRecord
        _image = State(initialValue: initialImage)
    }

    private var isSynthetic: Bool { model.snapshot.frame.source == .synthetic }
    private var failedValues: [MeasurementValue] {
        model.needsRecalculation ? [] : model.visibleValues.filter { !$0.hasUsableMeasurement }
    }
    private var incompleteCount: Int { failedValues.count }
    private var canCorrectSingleTotalLengthFailure: Bool {
        guard model.canCorrectTotalLength, failedValues.count == 1,
              let value = failedValues.first, value.id == "top.totalLength",
              let feedback = value.failureFeedback, !feedback.isCaptureFailure else { return false }
        return feedback.suggestedAction == .editPoints || feedback.suggestedAction == .correctTotalLength
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width <= geometry.size.height && !dynamicTypeSize.isAccessibilitySize {
                portraitResult(in: geometry.size)
            } else {
                accessibleResult
            }
        }
        .background { Color.white.ignoresSafeArea() }
        .navigationTitle("실측 결과")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onRetake) { GarmentCaptureToolbarIcon(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("다시 촬영")
                    .accessibilityIdentifier("retakeGarmentMeasurement")
                    .disabled(isSaving || isEditingPoint)
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { resultActions }
                .sharedBackgroundVisibility(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { Task { await confirm() } } label: {
                HStack(spacing: 10) {
                    if isSaving || model.needsRecalculation { ProgressView().tint(.white) }
                    Text(isSaving ? "저장 중…" : model.needsRecalculation ? "다시 측정 중…" : "다음")
                        .font(.system(.callout, design: .default, weight: .semibold)).italic()
                }.frame(maxWidth: .infinity).frame(minHeight: 62)
                    .background(GarmentCaptureStyle.accent, in: Capsule())
                    .contentShape(.interaction, Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .disabled(isSaving || isEditingPoint || model.needsRecalculation)
            .accessibilityHint(onConfirmedRecord == nil
                ? "사진과 확인한 측정 결과를 저장하고 촬영을 마칩니다"
                : "사진과 확인한 측정 결과를 저장하고 제품 상세 촬영으로 이동합니다")
            .accessibilityIdentifier("confirmGarmentMeasurement")
            .padding(.leading, 32).padding(.trailing, 35).padding(.top, 28)
            .background(Color.white)
        }
        .task {
            if let decoded = await SnapshotPresentation.thumbnail(for: model.snapshot), !Task.isCancelled {
                image = decoded
            }
            guard !Task.isCancelled else { return }
            if dynamicTypeSize.isAccessibilitySize { showDetails = true }
            presentPointTutorialIfNeeded()
        }
        .onChange(of: dynamicTypeSize) { _, size in if size.isAccessibilitySize { showDetails = true } }
        .onChange(of: model.needsRecalculation) { _, pending in
            if !pending { presentPointTutorialIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { presentPointTutorialIfNeeded() }
        }
        .task(id: model.calculationRevision) { await recalculate() }
        .sheet(item: $selectedDefinition) { definition in
            GarmentMeasurementItemSheet(model: model, definition: definition, archive: archive)
        }
        .sheet(isPresented: $showPhoto) {
            if let image { GarmentMeasurementPhotoSheet(image: image) }
        }
        .sheet(item: $manualReview) { measurement in
            MeasurementDetailView(model: measurement, archive: archive)
        }
        .sheet(item: $totalLengthCorrection) { measurement in
            totalLengthCorrectionSheet(measurement)
        }
        .sheet(isPresented: $showAuxiliaryDetails) { auxiliaryDetailsSheet }
        .fullScreenCover(isPresented: $showsPointTutorial) {
            GarmentResultPointTutorial {
                if !isSynthetic { hasSeenPointTutorial = true }
                showsPointTutorial = false
            }
            .presentationBackground(.clear)
            .interactiveDismissDisabled()
        }
        .alert("저장하지 못했어요", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("확인", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .tint(.primary).preferredColorScheme(.light)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentMeasurementResult")
    }

    private func portraitResult(in size: CGSize) -> some View {
        // Fit the actual capture inside the Hi-Fi photograph window. Points
        // and depth coordinates must not follow the reference image's crop.
        let topGap: CGFloat = 30
        let viewportHeight = min(size.width * 536 / 402, max(1, size.height - topGap))
        let aspect = SnapshotPresentation.resultAspectRatio(for: model.snapshot)
        let photoWidth = min(size.width, viewportHeight * aspect)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                // A distinct backing element exposes the window's bounds
                // without replacing the aspect-fit editor's accessibility ID.
                Rectangle().fill(Color.white)
                    .frame(width: size.width, height: viewportHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("실측 사진 표시 영역")
                    .accessibilityIdentifier("garmentResultPhotoViewport")
                    .accessibilitySortPriority(-1)
                    .allowsHitTesting(false)
                photoEditor(showsEnlargeControl: false)
                    .frame(width: photoWidth, height: photoWidth / aspect)
            }.frame(width: size.width, height: viewportHeight)
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if isSynthetic { syntheticBadge.allowsHitTesting(false) }
                    reviewNotice
                }.padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                if model.needsRecalculation {
                    pointRecalculation.padding(12).allowsHitTesting(false)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var accessibleResult: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                reviewNotice.padding(.horizontal, 20)
                if isSynthetic { syntheticBadge.padding(.horizontal, 20) }
                photoEditor(showsEnlargeControl: true)
                auxiliaryContent.padding(.horizontal, 20)
            }.padding(.top, 16).padding(.bottom, 24)
                .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
    }

    private func photoEditor(showsEnlargeControl: Bool) -> some View {
        GarmentMeasurementPhotoEditor(image: image, snapshot: model.snapshot,
            editableLandmarks: model.visibleEditableLandmarks,
            definitions: model.visibleDefinitions,
            values: model.visibleValues, showLabels: !dynamicTypeSize.isAccessibilitySize,
            isEnabled: !isSaving, isRecalculating: model.needsRecalculation,
            showsEnlargeControl: showsEnlargeControl,
            onSelect: { if !isEditingPoint && !model.needsRecalculation { selectedDefinition = $0 } },
            onEnlarge: { showPhoto = true }, onMove: { id, point in
                _ = model.placePoint(originalPoint: point, id: id)
            }, onEditingChanged: { isEditingPoint = $0 })
    }

    private func presentPointTutorialIfNeeded() {
        guard scenePhase == .active, !hasPresentedPointTutorial, image != nil,
              !model.needsRecalculation, !isSaving, !isEditingPoint,
              selectedDefinition == nil, manualReview == nil, totalLengthCorrection == nil,
              !showPhoto, !showAuxiliaryDetails,
              !model.visibleValues.isEmpty, incompleteCount == 0 else { return }
        // Synthetic flows stay deterministic and never consume the real first-
        // result preference. The opt-in exists only in Debug UI fixtures.
        if isSynthetic {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--garment-preview-result-tutorial") else { return }
            #else
            return
            #endif
        } else if hasSeenPointTutorial {
            return
        }
        hasPresentedPointTutorial = true
        showsPointTutorial = true
    }

    @ViewBuilder
    private var reviewNotice: some View {
        if incompleteCount > 0 {
            Button {
                if canCorrectSingleTotalLengthFailure { openManualReview(for: "top.totalLength") }
                else { openAuxiliaryDetails() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label(incompleteCount == 1 ? "\(failedValues[0].title) 측정 불가" : "\(incompleteCount)개 측정 불가",
                          systemImage: "exclamationmark.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(GarmentCaptureStyle.accent)
                    if let feedback = failedValues.first?.failureFeedback {
                        Text(feedback.reason).font(.caption2).foregroundStyle(.white).lineLimit(3)
                    }
                    Text("이유와 해결 방법 보기").font(.caption2).foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: 270, minHeight: 44, alignment: .leading)
                .background(GarmentCaptureStyle.background.opacity(0.94), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityHint(canCorrectSingleTotalLengthFailure
                    ? "사진에서 총장 상단과 밑단 위치를 직접 지정합니다"
                    : "실패한 항목과 원인, 다시 촬영하거나 측정점을 수정하는 방법을 확인합니다")
                .accessibilityIdentifier("garmentUnavailableNotice")
        }
    }

    private var syntheticBadge: some View {
        Label("화면 미리보기 · 합성 치수", systemImage: "cube.transparent")
            .font(.caption2.weight(.semibold)).foregroundStyle(GarmentCaptureStyle.accent)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(GarmentCaptureStyle.background.opacity(0.9), in: Capsule())
            .accessibilityIdentifier("garmentSyntheticResult")
    }

    private var pointRecalculation: some View {
        ProgressView("수정한 위치로 다시 측정 중…")
            .font(.caption).tint(GarmentCaptureStyle.accent).foregroundStyle(.white)
            .padding(8)
            .background(GarmentCaptureStyle.background.opacity(0.9), in: Capsule())
            .accessibilityIdentifier("garmentPointRecalculation")
    }

    private var resultActions: some View {
        Menu {
            Button("측정 항목 상세", systemImage: "list.bullet.rectangle") { openAuxiliaryDetails() }
                .accessibilityIdentifier("openGarmentMeasurementDetails")
            if model.canCorrectTotalLength {
                Button("총장 위치 직접 지정", systemImage: "hand.point.up.left") {
                    openManualReview(for: "top.totalLength")
                }.disabled(model.needsRecalculation)
                    .accessibilityIdentifier("correctGarmentTotalLength")
            }
            Button("촬영 사진 확대", systemImage: "arrow.up.left.and.arrow.down.right") { showPhoto = true }
                .disabled(image == nil)
                .accessibilityIdentifier("enlargeGarmentPhoto")
            Button("측정점 확인·수정", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                openAuxiliaryDetails()
            }.disabled(isSaving || isEditingPoint || model.needsRecalculation)
            if model.hasPointAdjustments {
                Button("원래 위치로", systemImage: "arrow.counterclockwise") { model.resetPointAdjustments() }
                    .disabled(isSaving || isEditingPoint)
                    .accessibilityIdentifier("resetGarmentMeasurementPoints")
            }
        } label: {
            GarmentCaptureToolbarIcon(systemName: "ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("실측 결과 메뉴")
        .accessibilityIdentifier("garmentResultActions")
        .disabled(isSaving || isEditingPoint)
    }

    private func openAuxiliaryDetails() {
        showDetails = true
        showAuxiliaryDetails = true
    }

    private var auxiliaryDetailsSheet: some View {
        NavigationStack {
            ScrollView {
                auxiliaryContent.padding(20)
                    .frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
            .background(GarmentCaptureStyle.background)
            .navigationTitle("측정 항목 상세").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { showAuxiliaryDetails = false }
                        .accessibilityIdentifier("closeGarmentMeasurementDetails")
                }
            }
            .sheet(item: $detailDefinition) { definition in
                GarmentMeasurementItemSheet(model: model, definition: definition, archive: archive)
            }
            .sheet(item: $detailManualReview) { measurement in
                MeasurementDetailView(model: measurement, archive: archive)
            }
            .sheet(item: $detailTotalLengthCorrection) { measurement in
                totalLengthCorrectionSheet(measurement)
            }
        }.tint(GarmentCaptureStyle.accent).preferredColorScheme(.dark)
    }

    private var auxiliaryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("점을 끌어 위치를 수정할 수 있어요. 치수를 누르면 상세를 볼 수 있어요.")
                .font(.caption).foregroundStyle(.secondary)
            if isSynthetic {
                Label("화면 미리보기 · 합성 치수", systemImage: "cube.transparent")
                    .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                Text("이 결과는 화면 검증용 합성 사진과 치수예요. 실제 옷의 인식률이나 실측 정확도를 나타내지 않아요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.needsRecalculation {
                pointRecalculation
            }
            if model.hasPointAdjustments {
                HStack(alignment: .firstTextBaseline) {
                    Label("측정점 \(model.editedPointIDs.count)개 수동 보정", systemImage: "hand.draw")
                        .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                        .accessibilityIdentifier("garmentMeasurementAdjustmentStatus")
                    Spacer(minLength: 8)
                    Button("원래 위치로") { model.resetPointAdjustments() }
                        .font(.caption.weight(.semibold)).disabled(isSaving || isEditingPoint)
                        .accessibilityIdentifier("resetGarmentMeasurementPoints")
                }
            }
            Menu {
                ForEach(model.visibleDefinitions.filter { $0.landmarkIDs.count == 2 }) { definition in
                    Button(definition.title) { openManualReview(for: definition.id) }
                        .accessibilityIdentifier("reviewGarmentItem_\(definition.id)")
                }
            } label: {
                Label("측정점 확인·수정", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.subheadline.weight(.semibold))
            }.tint(GarmentCaptureStyle.accent)
                .disabled(isSaving || isEditingPoint || model.needsRecalculation)
                .accessibilityHint("총장 위치 지정은 현재 실측 결과에 반영됩니다. 다른 항목의 수동 검증은 별도로 저장됩니다")
                .accessibilityIdentifier("reviewAllGarmentMeasurementPoints")
            if incompleteCount > 0 {
                Label("\(incompleteCount)개 항목은 측정하지 못했어요. 상세에서 이유를 확인해 주세요.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(GarmentCaptureStyle.accent)
                    .accessibilityIdentifier("garmentUnavailableSummary")
            }
            if !failedValues.isEmpty {
                reviewNeededMeasurements
                    .disabled(isSaving || isEditingPoint || model.needsRecalculation)
            }
            DisclosureGroup("측정 항목 상세", isExpanded: $showDetails) {
                VStack(spacing: 0) {
                    ForEach(model.visibleValues) { value in
                        if let definition = model.visibleDefinitions.first(where: { $0.id == value.id }) {
                            Button { openMeasurementDetail(definition) } label: { measurementRow(value) }
                                .buttonStyle(.plain).disabled(isEditingPoint || model.needsRecalculation)
                        }
                    }
                }.padding(.top, 8)
            }.accessibilityElement(children: .contain)
                .accessibilityIdentifier("garmentMeasurementDetails")
            if let recordingError {
                Text("촬영 시도 기록을 완료하지 못했어요. 측정 결과는 확인을 눌러 따로 저장할 수 있어요.\n\(recordingError)")
                    .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
            }
            Text(measurementGuide)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func openMeasurementDetail(_ definition: MeasurementDefinition) {
        if showAuxiliaryDetails { detailDefinition = definition }
        else { selectedDefinition = definition }
    }

    private func openManualReview(for definitionID: String) {
        let measurement = model.manualMeasurement(for: definitionID)
        if definitionID == "top.totalLength", model.canCorrectTotalLength {
            if showAuxiliaryDetails { detailTotalLengthCorrection = measurement }
            else { totalLengthCorrection = measurement }
        } else if showAuxiliaryDetails { detailManualReview = measurement }
        else { manualReview = measurement }
    }

    private func totalLengthCorrectionSheet(_ measurement: ManualMeasurement) -> some View {
        GarmentTotalLengthCorrectionView(model: measurement, initialImage: image,
            failure: model.result.values.first { $0.id == "top.totalLength" }?.failure,
            failureFeedback: model.result.values.first { $0.id == "top.totalLength" }?.failureFeedback) { correction in
                guard !isSaving, !isEditingPoint, !model.needsRecalculation else { return false }
                return model.applyTotalLengthCorrection(from: correction)
            }
    }

    private var measurementGuide: String {
        guard let total = model.definitions.first(where: { $0.id == "top.totalLength" }) else {
            return "펼친 옷의 두 점 사이 직선거리예요. 주름이나 굽은 봉제선을 따라 잰 길이와 다를 수 있어요."
        }
        let totalGuide = total.landmarkIDs.first == "top_length_start"
            ? "총장은 옷 윤곽의 상단과 밑단 중앙 사이의 거리예요. 카라가 높은 옷은 상단 위치를 확인해 주세요."
            : total.projection == nil ? "총장은 목 중앙과 밑단 중앙 사이의 직선거리예요."
                : "이 이전 기록의 총장은 목 좌우 축에 수직인 길이예요."
        return "단면과 소매는 두 점 사이 직선거리이며, " + totalGuide
            + " 소매를 곧게 펼치고 측정점을 눈으로 확인해 주세요. 민소매의 소매길이는 사용할 수 없어요."
    }

    private var reviewDefinitions: [MeasurementDefinition] {
        let ids = Set(failedValues.filter { $0.failureFeedback?.isCaptureFailure != true }.map(\.id))
        return model.visibleDefinitions.filter { ids.contains($0.id) && $0.landmarkIDs.count == 2 }
    }

    /// One frozen-capture failure can affect every length. Explain it once
    /// instead of repeating the same instruction for each measurement.
    private var captureFailureGroups: [MeasurementCaptureFailureGroup] {
        var groups: [MeasurementCaptureFailureGroup] = []
        for value in failedValues {
            guard let feedback = value.failureFeedback, feedback.isCaptureFailure else { continue }
            if let index = groups.firstIndex(where: {
                $0.feedback.reason == feedback.reason && $0.feedback.recovery == feedback.recovery
            }) {
                groups[index].titles.append(value.title)
            } else {
                groups.append(.init(id: value.id, titles: [value.title], feedback: feedback))
            }
        }
        return groups
    }

    @ViewBuilder
    private func failureRecoveryButton(for definition: MeasurementDefinition,
                                       feedback: MeasurementFailureFeedback) -> some View {
        switch feedback.suggestedAction {
        case .editPoints, .correctTotalLength:
            Button(definition.id == "top.totalLength" && model.canCorrectTotalLength
                   ? "총장 위치 지정하고 다시 측정" : "이 사진에서 측정점 직접 확인") {
                openManualReview(for: definition.id)
            }.buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                .accessibilityLabel("\(definition.title) 측정점 직접 확인")
                .accessibilityIdentifier("reviewGarmentMeasurement_\(definition.id)")
        case .retry:
            Button("다시 계산") { model.requestRecalculation() }
                .buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                .accessibilityIdentifier("retryGarmentMeasurement_\(definition.id)")
        case .retake, .none:
            Button("다시 촬영") { onRetake() }
                .buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                .accessibilityIdentifier("retakeForMeasurementFailure_\(definition.id)")
        }
    }

    private var reviewNeededMeasurements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("측정하지 못한 항목과 해결 방법").font(.subheadline.weight(.semibold))
            ForEach(captureFailureGroups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.titles.joined(separator: ", ")).font(.subheadline.weight(.medium))
                    Text(group.feedback.reason).font(.caption)
                    Text(group.feedback.recovery).font(.caption).foregroundStyle(.secondary)
                    if group.feedback.suggestedAction == .retry {
                        Button("다시 계산") { model.requestRecalculation() }
                            .buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("retryGarmentMeasurement_\(group.id)")
                    } else {
                        Button("다시 촬영") { onRetake() }
                            .buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("retakeForMeasurementFailure_\(group.id)")
                    }
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("garmentCaptureFailureReason")
            }
            ForEach(reviewDefinitions) { definition in
                VStack(alignment: .leading, spacing: 6) {
                    if let value = model.result.values.first(where: { $0.id == definition.id }) {
                        Text("\(definition.title) · \(GarmentMeasurementText.value(value))")
                            .font(.subheadline.weight(.medium))
                        MeasurementFailureFeedbackView(value: value)
                        if let feedback = value.failureFeedback {
                            failureRecoveryButton(for: definition, feedback: feedback)
                        }
                    }
                }
            }
            if reviewDefinitions.contains(where: { definition in
                let action = failedValues.first { $0.id == definition.id }?.failureFeedback?.suggestedAction
                return action == .editPoints || action == .correctTotalLength
            }) {
                Text(model.canCorrectTotalLength
                     ? "총장 위치 지정은 현재 결과에 반영돼요. 다른 항목의 수동 검증은 별도 기록으로 저장돼요."
                     : "두 점을 직접 확인하면 별도의 수동 측정으로 저장돼요. 자동 측정 기록은 그대로 유지돼요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("garmentMeasurementReviewActions")
    }

    private func measurementRow(_ value: MeasurementValue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(value.title)
                    Spacer(minLength: 8)
                    Text(GarmentMeasurementText.value(value)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.title)
                    Text(GarmentMeasurementText.value(value)).monospacedDigit()
                }
            }.font(.subheadline.weight(.medium))
            if !model.needsRecalculation, !value.hasUsableMeasurement {
                if value.failureFeedback?.isCaptureFailure == true {
                    Text("촬영 데이터 문제 · 위의 공통 원인 안내를 확인해 주세요")
                        .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                } else {
                    MeasurementFailureFeedbackView(value: value)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("garmentMeasurementValue_\(value.id)")
    }

    private func confirm() async {
        guard !isSaving, !isEditingPoint, !model.needsRecalculation else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if pendingRecord == nil || pendingRecordRevision != model.persistenceRevision {
                pendingRecord = try model.makeRecord()
                pendingRecordRevision = model.persistenceRevision
                pendingRecordArchived = false
            }
            guard let record = pendingRecord else { return }
            if !pendingRecordArchived {
                _ = try await archive.save(record)
                pendingRecordArchived = true
            }
            // A downstream storage failure retries the same confirmed record;
            // the already published immutable archive is not saved twice.
            try await onConfirmedRecord?(record)
            onConfirm()
        } catch { saveError = error.localizedDescription }
    }

    private func recalculate() async {
        guard model.needsRecalculation else { return }
        let input = model, revision = model.calculationRevision, runID = UUID()
        calculationRunID = runID
        // Coalesce accessibility nudges and fast successive edits. The
        // pipeline runs off the UI actor; revision checks reject late results.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        let result = await pipeline.measure(snapshot: input.snapshot, landmarks: input.calculationLandmarks,
            definitions: input.definitions, options: input.options)
        guard !Task.isCancelled, calculationRunID == runID else { return }
        _ = model.apply(result, for: revision)
    }
}

private struct MeasurementCaptureFailureGroup: Identifiable {
    let id: String
    var titles: [String]
    let feedback: MeasurementFailureFeedback
}

/// A first-result guide, rather than an extra step in the capture pipeline.
/// The illustration is the original 76 × 111 Figma asset, not a symbol substitute.
private struct GarmentResultPointTutorial: View {
    let dismiss: () -> Void
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            Button(action: dismiss) {
                ZStack {
                    Color.black.opacity(0.57)
                    ViewThatFits(in: .vertical) {
                        content
                        ScrollView { content.padding(.vertical, 24) }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 44)
                    .offset(y: -26)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("자동 실측 완료. 직접 측정점을 움직일 수 있어요. 안내 닫기")
            .accessibilityHint("화면을 탭하면 측정점과 길이를 확인하고 수정할 수 있어요")
            .accessibilityIdentifier("dismissGarmentResultTutorial")
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
    }

    private var content: some View {
        VStack(spacing: 22) {
            Text("자동 실측 완료!")
                .font(.system(size: titleSize, weight: .bold))
                .frame(minHeight: 26)
            Image("MeasurementPointTutorial")
                .resizable().scaledToFit().frame(width: 76, height: 111)
            VStack(spacing: 0) {
                Text("직접 측정점을 움직일 수 있어요")
                    .font(.callout.bold()).frame(minHeight: 26)
                Text("화면을 터치해서 확인해주세요!")
                    .font(.subheadline).frame(minHeight: 26)
            }
        }
        .foregroundStyle(.white).multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 4)
        .accessibilityHidden(true)
    }
}

enum GarmentMeasurementText {
    static func value(_ value: MeasurementValue) -> String {
        guard value.hasUsableMeasurement, let meters = value.meters else { return "측정 불가" }
        return MeasurementDisplayText.centimeters(meters * 100) + " cm"
    }

    static func shortTitle(_ definition: MeasurementDefinition) -> String {
        let fallback: String
        switch definition.id {
        case "bottom.waist_left.waist_right": fallback = "허리"
        case "bottom.crotch.waist_center", "bottom.crotch.waist_front_center": fallback = "밑위"
        case "bottom.thighWidthRight": fallback = "허벅지"
        case "top.shoulderWidth": fallback = "어깨"
        case "top.chestWidth": fallback = "가슴"
        case "top.hemWidth": fallback = "밑단"
        case "top.totalLength": fallback = "총장"
        default: fallback = definition.title
        }
        return GarmentMeasurementPresentation.shortTitle(for: definition.id, fallback: fallback)
    }
}

private struct GarmentMeasurementItemSheet: View {
    let model: AutomaticMeasurement
    let definition: MeasurementDefinition
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss
    @State private var manualComparison: ManualMeasurement?

    var body: some View {
        NavigationStack {
            Form {
                if let value = model.result.values.first(where: { $0.id == definition.id }) {
                    Section {
                        Text(GarmentMeasurementText.value(value)).font(.largeTitle.bold()).monospacedDigit()
                        Text(value.hasUsableMeasurement ? "계산 완료" : "측정 불가")
                            .foregroundStyle(value.hasUsableMeasurement ? Color.primary : GarmentCaptureStyle.accent)
                        MeasurementFailureFeedbackView(value: value)
                    }
                }
                Section {
                    Text(definition.id == "top.totalLength"
                         ? definition.landmarkIDs.first == "top_length_start"
                            ? "총장 상단과 밑단 중앙 사이의 거리예요. 자동 상단은 옷 윤곽을 기준으로 잡으므로, 카라가 높은 옷은 위치를 확인해 주세요. 줄자도 같은 두 점을 기준으로 비교해 주세요."
                            : definition.projection == nil
                            ? "목 중앙과 밑단 중앙 사이의 직선거리예요. 줄자도 옷을 펼친 상태에서 같은 두 점을 기준으로 비교해 주세요."
                            : "이 이전 기록은 목 좌우 축에 수직인 총장이에요. 줄자도 같은 기준으로 비교해 주세요."
                         : "사진에 표시된 두 점 사이의 직선거리예요. 줄자도 같은 두 점 사이를 기준으로 비교해 주세요.")
                    Button("이 사진에서 수동점 검증") {
                        manualComparison = model.manualMeasurement(for: definition.id)
                    }.disabled(definition.landmarkIDs.count != 2)
                        .accessibilityIdentifier("verifyGarmentMeasurement_\(definition.id)")
                } footer: {
                    Text("수동점 검증은 별도 기록으로 저장돼요. 결과 화면에서 확인한 치수는 바뀌지 않아요.")
                }
            }.navigationTitle(definition.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
                .sheet(item: $manualComparison) { measurement in
                    MeasurementDetailView(model: measurement, archive: archive)
                }
        }.tint(GarmentCaptureStyle.accent).preferredColorScheme(.dark)
    }
}

private struct GarmentMeasurementPhotoSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var previousScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                        .gesture(MagnificationGesture().onChanged { value in
                            scale = min(4, max(1, previousScale * value))
                        }.onEnded { _ in previousScale = scale })
                        .onTapGesture(count: 2) {
                            scale = scale > 1 ? 1 : 2
                            previousScale = scale
                        }
                        .accessibilityLabel("촬영한 원본 사진")
                }
            }.background(GarmentCaptureStyle.background)
                .navigationTitle("촬영 사진").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(scale > 1 ? "축소" : "확대") {
                            scale = scale > 1 ? 1 : 2
                            previousScale = scale
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
                }
        }.tint(.white).preferredColorScheme(.dark)
    }
}
