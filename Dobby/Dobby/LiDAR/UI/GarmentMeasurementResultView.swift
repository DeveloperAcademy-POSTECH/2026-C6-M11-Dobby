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
    @State private var image: UIImage?
    @State private var selectedDefinition: MeasurementDefinition?
    @State private var showPhoto = false
    @State private var showDetails = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var manualReview: ManualMeasurement?
    @State private var isEditingPoint = false
    @State private var calculationRunID: UUID?
    @State private var pendingRecord: SavedMeasurement?
    @State private var pendingRecordRevision: UUID?
    @State private var pendingRecordArchived = false
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
    private var incompleteCount: Int { model.result.values.filter { $0.status == .unavailable }.count }
    private var uncertainCount: Int { model.result.values.filter { $0.status == .uncertain }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading.padding(.horizontal, 20)
                GarmentMeasurementPhotoEditor(image: image, snapshot: model.snapshot,
                    editableLandmarks: model.editableLandmarks,
                    definitions: model.definitions,
                    values: model.result.values, showLabels: !dynamicTypeSize.isAccessibilitySize,
                    isEnabled: !isSaving, isRecalculating: model.needsRecalculation,
                    onSelect: { if !isEditingPoint && !model.needsRecalculation { selectedDefinition = $0 } },
                    onEnlarge: { showPhoto = true }, onMove: { id, point in
                        _ = model.placePoint(originalPoint: point, id: id)
                    }, onEditingChanged: { isEditingPoint = $0 })
                VStack(alignment: .leading, spacing: 16) {
                    Text("점을 끌어 위치를 수정할 수 있어요. 치수를 누르면 상세를 볼 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.needsRecalculation {
                        ProgressView("수정한 위치로 다시 측정 중…")
                            .font(.caption).tint(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("garmentPointRecalculation")
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
                        ForEach(model.definitions.filter { $0.landmarkIDs.count == 2 }) { definition in
                            Button(definition.title) {
                                manualReview = model.manualMeasurement(for: definition.id)
                            }.accessibilityIdentifier("reviewGarmentItem_\(definition.id)")
                        }
                    } label: {
                        Label("측정점 확인·수정", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.subheadline.weight(.semibold))
                    }.tint(GarmentCaptureStyle.accent)
                        .disabled(isSaving || isEditingPoint || model.needsRecalculation)
                        .accessibilityHint("항목을 고르면 같은 사진에서 두 점을 직접 확인하고 별도의 수동 측정으로 저장할 수 있습니다")
                        .accessibilityIdentifier("reviewAllGarmentMeasurementPoints")
                    if incompleteCount > 0 {
                        Label("\(incompleteCount)개 항목은 측정하지 못했어요. 상세에서 이유를 확인해 주세요.", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("garmentUnavailableSummary")
                    } else if uncertainCount > 0 {
                        Label("\(uncertainCount)개 항목은 확인이 필요해요. 줄자와 비교해 주세요.", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(GarmentCaptureStyle.accent)
                    }
                    if !reviewDefinitions.isEmpty {
                        reviewNeededMeasurements
                            .disabled(isSaving || isEditingPoint || model.needsRecalculation)
                    }
                    DisclosureGroup("측정 항목 상세", isExpanded: $showDetails) {
                        VStack(spacing: 0) {
                            ForEach(model.result.values) { value in
                                if let definition = model.definitions.first(where: { $0.id == value.id }) {
                                    Button { selectedDefinition = definition } label: {
                                        measurementRow(value)
                                    }.buttonStyle(.plain)
                                        .disabled(isEditingPoint || model.needsRecalculation)
                                }
                            }
                        }.padding(.top, 8)
                    }.accessibilityElement(children: .contain)
                        .accessibilityIdentifier("garmentMeasurementDetails")
                    if let recordingError {
                        Text("촬영 시도 기록을 완료하지 못했어요. 측정 결과는 확인을 눌러 따로 저장할 수 있어요.\n\(recordingError)")
                            .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                    }
                    Text(model.definitions.contains(where: { $0.id == "top.totalLength" })
                         ? "단면과 소매는 두 점 사이 직선거리이며, 총장은 목 좌우 축에 수직인 길이예요. 소매를 곧게 펼치고 측정점을 눈으로 확인해 주세요. 민소매의 소매길이는 사용할 수 없어요."
                         : "펼친 옷의 두 점 사이 직선거리예요. 주름이나 굽은 봉제선을 따라 잰 길이와 다를 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20)
            }.padding(.top, 20).padding(.bottom, 24)
                .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .background(GarmentCaptureStyle.background)
        .navigationTitle("실측 결과")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbarBackground(GarmentCaptureStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onRetake) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("다시 촬영")
                    .accessibilityIdentifier("retakeGarmentMeasurement")
                    .disabled(isSaving || isEditingPoint)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { Task { await confirm() } } label: {
                HStack(spacing: 10) {
                    if isSaving || model.needsRecalculation { ProgressView().tint(.white) }
                    Text(isSaving ? "저장 중…" : model.needsRecalculation ? "다시 측정 중…" : "확인").font(.headline)
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(GarmentCaptureStyle.accent, in: Capsule())
            .disabled(isSaving || isEditingPoint || model.needsRecalculation)
            .accessibilityHint(onConfirmedRecord == nil
                ? "사진과 확인한 측정 결과를 저장하고 촬영을 마칩니다"
                : "사진과 확인한 측정 결과를 저장하고 제품 상세 촬영으로 이동합니다")
            .accessibilityIdentifier("confirmGarmentMeasurement")
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
            .background(GarmentCaptureStyle.background)
        }
        .task {
            if let decoded = await SnapshotPresentation.thumbnail(for: model.snapshot), !Task.isCancelled {
                image = decoded
            }
            if dynamicTypeSize.isAccessibilitySize { showDetails = true }
        }
        .onChange(of: dynamicTypeSize) { _, size in if size.isAccessibilitySize { showDetails = true } }
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
        .alert("저장하지 못했어요", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("확인", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
        .tint(.white).preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentMeasurementResult")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.hasPointAdjustments ? "측정 위치를 조정했어요" : incompleteCount == 0 && uncertainCount == 0 ? "자동으로 실측을 완료했어요" : "측정 결과를 확인해 주세요")
                .font(.system(.title3, design: .default, weight: .bold))
            Text("점을 선택하면 왼쪽 위에서 자세히 볼 수 있어요.")
                .font(.footnote).foregroundStyle(.secondary)
            if isSynthetic {
                Label("화면 미리보기 · 합성 치수", systemImage: "cube.transparent")
                    .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                    .accessibilityIdentifier("garmentSyntheticResult")
            }
        }
    }

    private var reviewDefinitions: [MeasurementDefinition] {
        let ids = Set(model.result.values.filter { $0.status != .valid }.map(\.id))
        return model.definitions.filter { ids.contains($0.id) && $0.landmarkIDs.count == 2 }
    }

    private var reviewNeededMeasurements: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("확인이 필요한 측정점").font(.subheadline.weight(.semibold))
            ForEach(reviewDefinitions) { definition in
                VStack(alignment: .leading, spacing: 6) {
                    if let value = model.result.values.first(where: { $0.id == definition.id }) {
                        Text("\(definition.title) · \(GarmentMeasurementText.value(value))")
                            .font(.subheadline.weight(.medium))
                        if let failure = value.failure {
                            Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("이 사진에서 측정점 직접 확인") {
                        manualReview = model.manualMeasurement(for: definition.id)
                    }.buttonStyle(.bordered).tint(GarmentCaptureStyle.accent)
                        .accessibilityLabel("\(definition.title) 측정점 직접 확인")
                        .accessibilityIdentifier("reviewGarmentMeasurement_\(definition.id)")
                }
            }
            Text("두 점을 직접 확인하면 별도의 수동 측정으로 저장돼요. 자동 측정 기록은 그대로 유지돼요.")
                .font(.caption).foregroundStyle(.secondary)
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
            if value.status != .valid {
                Text(value.failure?.message ?? "확인 필요 · 줄자로 비교해 주세요")
                    .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
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

enum GarmentMeasurementText {
    static func value(_ value: MeasurementValue) -> String {
        guard value.status != .unavailable, let meters = value.meters,
              meters.isFinite, meters > 0 else { return "측정 불가" }
        return MeasurementDisplayText.centimeters(meters * 100) + " cm"
    }

    static func shortTitle(_ definition: MeasurementDefinition) -> String {
        switch definition.id {
        case "bottom.waist_left.waist_right": "허리"
        case "bottom.crotch.waist_center": "밑위"
        case "bottom.hem_left_outer.waist_left": "왼 총장"
        case "bottom.hem_right_outer.waist_right": "오른 총장"
        case "bottom.hem_left_inner.hem_left_outer": "왼 밑단"
        case "bottom.hem_right_inner.hem_right_outer": "오른 밑단"
        case "bottom.crotch.hem_left_inner": "왼 인심"
        case "bottom.crotch.hem_right_inner": "오른 인심"
        case "top.shoulderWidth": "어깨"
        case "top.chestWidth": "가슴"
        case "top.hemWidth": "밑단"
        case "top.sleeveLengthLeft": "왼 소매"
        case "top.sleeveLengthRight": "오른 소매"
        case "top.totalLength": "총장"
        default: definition.title
        }
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
                        Text(value.status.label)
                            .foregroundStyle(value.status == .valid ? Color.primary : GarmentCaptureStyle.accent)
                        if let failure = value.failure { Text(failure.message).font(.subheadline) }
                        if value.status == .uncertain {
                            Text("측정점 또는 깊이 품질을 확인한 뒤 줄자로 비교해 주세요.").font(.subheadline)
                        }
                    }
                }
                Section {
                    Text(definition.id == "top.totalLength"
                         ? "목 좌우 점을 이은 축에 수직인 총장이에요. 줄자도 옷을 펼친 상태에서 같은 기준으로 비교해 주세요."
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
