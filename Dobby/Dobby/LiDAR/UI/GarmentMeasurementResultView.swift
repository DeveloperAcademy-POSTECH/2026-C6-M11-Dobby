import SwiftUI
import UIKit

/// The product result keeps the automatic observation intact. Manual checks
/// create separate records through the existing measurement editor.
struct GarmentMeasurementResultView: View {
    @State private var model: AutomaticMeasurement
    let archive: MeasurementArchive
    let recordingError: String?
    let onRetake: () -> Void
    let onConfirm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var image: UIImage?
    @State private var selectedDefinition: MeasurementDefinition?
    @State private var showPhoto = false
    @State private var showDetails = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(model: AutomaticMeasurement, archive: MeasurementArchive,
         recordingError: String? = nil, onRetake: @escaping () -> Void,
         onConfirm: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.archive = archive
        self.recordingError = recordingError
        self.onRetake = onRetake
        self.onConfirm = onConfirm
    }

    private var isSynthetic: Bool { model.snapshot.frame.source == .synthetic }
    private var incompleteCount: Int { model.result.values.filter { $0.status == .unavailable }.count }
    private var uncertainCount: Int { model.result.values.filter { $0.status == .uncertain }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading.padding(.horizontal, 20)
                GarmentMeasuredPhoto(image: image, snapshot: model.snapshot,
                    landmarks: model.displayLandmarks, definitions: model.definitions,
                    values: model.result.values, showLabels: !dynamicTypeSize.isAccessibilitySize,
                    onSelect: { selectedDefinition = $0 }, onEnlarge: { showPhoto = true })
                VStack(alignment: .leading, spacing: 16) {
                    Text("치수를 누르면 측정 항목을 자세히 볼 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                    if incompleteCount > 0 {
                        Label("\(incompleteCount)개 항목은 측정하지 못했어요. 상세에서 이유를 확인해 주세요.", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(GarmentCaptureStyle.accent)
                            .accessibilityIdentifier("garmentUnavailableSummary")
                    } else if uncertainCount > 0 {
                        Label("\(uncertainCount)개 항목은 확인이 필요해요. 줄자와 비교해 주세요.", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(GarmentCaptureStyle.accent)
                    }
                    DisclosureGroup("측정 항목 상세", isExpanded: $showDetails) {
                        VStack(spacing: 0) {
                            ForEach(model.result.values) { value in
                                if let definition = model.definitions.first(where: { $0.id == value.id }) {
                                    Button { selectedDefinition = definition } label: {
                                        measurementRow(value)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(.top, 8)
                    }.accessibilityElement(children: .contain)
                        .accessibilityIdentifier("garmentMeasurementDetails")
                    if let recordingError {
                        Text("촬영 시도 기록을 완료하지 못했어요. 측정 결과는 확인을 눌러 따로 저장할 수 있어요.\n\(recordingError)")
                            .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                    }
                    Text("펼친 하의의 두 점 사이 직선거리예요. 주름이나 굽은 봉제선을 따라 잰 길이와 다를 수 있어요.")
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
                    .disabled(isSaving)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { Task { await confirm() } } label: {
                HStack(spacing: 10) {
                    if isSaving { ProgressView().tint(.white) }
                    Text(isSaving ? "저장 중…" : "확인").font(.headline)
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(GarmentCaptureStyle.accent, in: Capsule())
            .disabled(isSaving)
            .accessibilityHint("사진과 자동 측정 결과를 저장하고 촬영을 마칩니다")
            .accessibilityIdentifier("confirmGarmentMeasurement")
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 12)
            .background(GarmentCaptureStyle.background)
        }
        .task {
            if image == nil { image = SnapshotPresentation.image(for: model.snapshot) }
            if dynamicTypeSize.isAccessibilitySize { showDetails = true }
        }
        .onChange(of: dynamicTypeSize) { _, size in if size.isAccessibilitySize { showDetails = true } }
        .sheet(item: $selectedDefinition) { definition in
            GarmentMeasurementItemSheet(model: model, definition: definition, archive: archive)
        }
        .sheet(isPresented: $showPhoto) {
            if let image { GarmentMeasurementPhotoSheet(image: image) }
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
            Text(incompleteCount == 0 ? "자동으로 실측을 완료했어요" : "측정 결과를 확인해 주세요")
                .font(.system(.title3, design: .default, weight: .bold))
            Text("사진 속 측정점과 치수를 확인해 주세요.")
                .font(.footnote).foregroundStyle(.secondary)
            if isSynthetic {
                Label("화면 미리보기 · 합성 치수", systemImage: "cube.transparent")
                    .font(.caption).foregroundStyle(GarmentCaptureStyle.accent)
                    .accessibilityIdentifier("garmentSyntheticResult")
            }
        }
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
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await archive.save(model.makeRecord())
            onConfirm()
        } catch { saveError = error.localizedDescription }
    }
}

private enum GarmentMeasurementText {
    static func value(_ value: MeasurementValue) -> String {
        guard value.status != .unavailable, let meters = value.meters,
              meters.isFinite, meters > 0 else { return "측정 불가" }
        return String(format: "%.1f cm", meters * 100)
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
        default: definition.title
        }
    }
}

/// The image and annotations share exactly the same aspect-fit rectangle.
/// Normalized coordinates describe the original sensor image, not screen pixels.
private struct GarmentMeasuredPhoto: View {
    @ScaledMetric(relativeTo: .caption) private var regularLabelHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .caption) private var uncertainLabelHeight: CGFloat = 48
    let image: UIImage?
    let snapshot: CaptureSnapshot
    let landmarks: GarmentLandmarkSet
    let definitions: [MeasurementDefinition]
    let values: [MeasurementValue]
    let showLabels: Bool
    let onSelect: (MeasurementDefinition) -> Void
    let onEnlarge: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let annotations = annotations(in: geometry.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel("촬영한 옷과 자동 측정점")
                } else {
                    ContentUnavailableView("사진을 불러올 수 없어요", systemImage: "photo")
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                Canvas { context, size in
                    for item in annotations {
                        var path = Path()
                        path.move(to: item.start)
                        path.addLine(to: item.end)
                        context.stroke(path, with: .color(.black.opacity(0.45)), lineWidth: 3)
                        context.stroke(path, with: .color(.white), style: .init(lineWidth: 1.5, dash: [5, 5]))
                        let middle = CGPoint(x: (item.start.x + item.end.x) / 2, y: (item.start.y + item.end.y) / 2)
                        if showLabels, let center = item.labelCenter,
                           hypot(center.x - middle.x, center.y - middle.y) > 12 {
                            var leader = Path()
                            leader.move(to: middle)
                            leader.addLine(to: center)
                            context.stroke(leader, with: .color(.white.opacity(0.65)), lineWidth: 1)
                        }
                    }
                    for point in landmarks.points where point.isVisible && point.point.isValid {
                        let center = screenPoint(point.point, size: size)
                        let dot = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                        context.fill(dot, with: .color(.white))
                    }
                }.allowsHitTesting(false).accessibilityHidden(true)
                if showLabels {
                    ForEach(annotations) { item in
                        if let center = item.labelCenter {
                            Button { onSelect(item.definition) } label: {
                                VStack(spacing: 2) {
                                    Text("\(GarmentMeasurementText.shortTitle(item.definition)) \(GarmentMeasurementText.value(item.value))")
                                        .lineLimit(1).minimumScaleFactor(0.75)
                                    if item.value.status == .uncertain { Text("확인 필요").foregroundStyle(GarmentCaptureStyle.accent) }
                                }.font(.caption.weight(.semibold)).foregroundStyle(.white)
                                    .multilineTextAlignment(.center).lineLimit(2)
                                    .padding(.horizontal, 8).frame(width: item.labelSize.width, height: item.labelSize.height)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }.buttonStyle(.plain)
                                .position(center)
                                .accessibilityLabel("\(item.definition.title), \(GarmentMeasurementText.value(item.value)), \(item.value.status.label)")
                                .accessibilityHint("측정 항목 상세 보기")
                                .accessibilityIdentifier("garmentMeasurementLabel_\(item.id)")
                        }
                    }
                }
                if let image {
                    Button(action: onEnlarge) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 44, height: 60).clipped()
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus").font(.caption.bold()).padding(5)
                                    .background(.regularMaterial, in: Circle())
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.6), lineWidth: 1))
                    }.buttonStyle(.plain).padding(12)
                        .accessibilityLabel("촬영 사진 확대")
                        .accessibilityIdentifier("enlargeGarmentPhoto")
                }
            }.clipped()
        }.aspectRatio(SnapshotPresentation.aspectRatio(for: snapshot), contentMode: .fit)
    }

    private struct Annotation: Identifiable {
        let definition: MeasurementDefinition
        let value: MeasurementValue
        let start: CGPoint
        let end: CGPoint
        let labelCenter: CGPoint?
        let labelSize: CGSize
        var id: String { definition.id }
    }

    private func annotations(in size: CGSize) -> [Annotation] {
        var occupied: [CGRect] = [CGRect(x: 8, y: 8, width: 56, height: 76)]
        return definitions.compactMap { definition in
            guard definition.landmarkIDs.count == 2,
                  let value = values.first(where: { $0.id == definition.id }),
                  value.status != .unavailable, let meters = value.meters, meters.isFinite, meters > 0,
                  let a = landmarks.points.first(where: { $0.id == definition.landmarkIDs[0] && $0.isVisible && $0.point.isValid }),
                  let b = landmarks.points.first(where: { $0.id == definition.landmarkIDs[1] && $0.isVisible && $0.point.isValid }) else { return nil }
            let start = screenPoint(a.point, size: size), end = screenPoint(b.point, size: size)
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            let labelSize = CGSize(width: min(142, size.width * 0.43),
                height: value.status == .uncertain ? uncertainLabelHeight : regularLabelHeight)
            let placement = labelPlacement(near: middle, labelSize: labelSize, imageSize: size, occupied: occupied)
            if let placement { occupied.append(placement) }
            return Annotation(definition: definition, value: value, start: start, end: end,
                labelCenter: placement.map { CGPoint(x: $0.midX, y: $0.midY) }, labelSize: labelSize)
        }
    }

    private func labelPlacement(near middle: CGPoint, labelSize: CGSize,
                                imageSize: CGSize, occupied: [CGRect]) -> CGRect? {
        let maxX = imageSize.width - labelSize.width - 4
        let maxY = imageSize.height - labelSize.height - 4
        guard maxX >= 4, maxY >= 4 else { return nil }
        let desiredX = min(max(4, middle.x - labelSize.width / 2), maxX)
        let desiredY = min(max(4, middle.y - labelSize.height / 2), maxY)
        // A free rectangle can start beside any occupied edge. Including the
        // exact edges avoids missing narrow gaps with a coarse search grid.
        // If the photo has no room, the full value remains in the details.
        let xs = ([desiredX, 4, maxX] + occupied.flatMap { [$0.minX - labelSize.width - 4, $0.maxX + 4] })
            .filter { $0 >= 4 && $0 <= maxX }
        let ys = ([desiredY, 4, maxY] + occupied.flatMap { [$0.minY - labelSize.height - 4, $0.maxY + 4] })
            .filter { $0 >= 4 && $0 <= maxY }
        var best: CGRect?
        var bestDistance = CGFloat.infinity
        for y in ys {
            for x in xs {
                let distance = pow(x - desiredX, 2) + pow(y - desiredY, 2)
                guard distance < bestDistance else { continue }
                let candidate = CGRect(x: x, y: y, width: labelSize.width, height: labelSize.height)
                guard !occupied.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(candidate) }) else { continue }
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    private func screenPoint(_ point: ImagePoint, size: CGSize) -> CGPoint {
        let display = ImageCoordinateTransform.originalToDisplay(point, orientation: snapshot.frame.orientation)
        return CGPoint(x: display.x * size.width, y: display.y * size.height)
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
                    Text("사진에 표시된 두 점 사이의 직선거리예요. 줄자도 같은 두 점 사이를 기준으로 비교해 주세요.")
                    Button("이 사진에서 수동점 검증") {
                        manualComparison = model.manualMeasurement(for: definition.id)
                    }.disabled(definition.landmarkIDs.count != 2)
                        .accessibilityIdentifier("verifyGarmentMeasurement_\(definition.id)")
                } footer: {
                    Text("수동점 검증은 별도 기록으로 저장돼요. 이 화면의 자동 측정값은 바뀌지 않아요.")
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
