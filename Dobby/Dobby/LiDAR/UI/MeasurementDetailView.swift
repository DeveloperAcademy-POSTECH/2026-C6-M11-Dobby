import SwiftUI

struct MeasurementDetailView: View {
    @ObservedObject var model: MeasurementSessionModel
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(model.snapshot.frame.source == .synthetic ? "합성 데이터 · 센서 정확도 검증용이 아닙니다" : "동일 프레임의 원본 사진 + LiDAR 깊이", systemImage: model.snapshot.frame.source == .synthetic ? "cube.transparent" : "checkmark.shield")
                        .font(.caption.weight(.semibold)).foregroundStyle(model.snapshot.frame.source == .synthetic ? .orange : .teal)
                    MeasurementImageView(model: model)
                        .aspectRatio(model.displayedAspectRatio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Text("A와 B를 차례로 누르거나 점을 끌어 위치를 바꾸세요. 옷의 경계가 사진 밖으로 잘리면 측정할 수 없습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        ForEach(Array(model.landmarks.points.enumerated()), id: \.offset) { index, point in
                            Button { model.activePointIndex = index } label: {
                                Label("\(index == 0 ? "A" : "B") \(point.isVisible ? "지정됨" : "위치 지정")", systemImage: point.isVisible ? "checkmark.circle.fill" : "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).tint(model.activePointIndex == index ? .teal : .gray)
                        }
                    }
                    Picker("옷 종류", selection: Binding(get: { model.testContext.category }, set: { model.selectCategory($0) })) {
                        ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).accessibilityIdentifier("garmentCategory")
                    Picker("측정 항목", selection: Binding(get: { model.definition.id }, set: { id in
                        if let definition = model.availableDefinitions.first(where: { $0.id == id }) {
                            model.selectDefinition(definition)
                        }
                    })) {
                        ForEach(model.availableDefinitions) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.menu).accessibilityIdentifier("measurementDefinition")
                    Text(GarmentMeasurementCatalog.guide(for: model.definition.id))
                        .font(.caption).foregroundStyle(.secondary)

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
                            TextField("줄자로 잰 길이", text: $model.referenceText).keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("referenceCentimeters")
                                .onChange(of: model.referenceText) { _, _ in model.exportedURL = nil }
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
                        Toggle("주변 평면으로 깊이 안정화", isOn: $model.useLocalPlane)
                            .onChange(of: model.useLocalPlane) { _, _ in model.recalculate() }
                        Text("평면에 잘 맞는 표본이 있을 때만 원래 측정점의 깊이를 보완합니다. 기울어진 평면에도 적용합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()

                    VStack(alignment: .leading, spacing: 12) {
                        Button { Task { await model.save(to: archive) } } label: {
                            HStack {
                                if model.isSaving { ProgressView().tint(.white) }
                                Label("테스트 기록 저장", systemImage: "square.and.arrow.down")
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).disabled(model.isSaving || model.isCalculating || model.result == nil)
                            .accessibilityIdentifier("saveMeasurement")
                        if let url = model.exportedURL {
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
                .task { model.recalculate() }
                .onChange(of: model.testContext) { _, _ in model.exportedURL = nil }
                .alert("저장하지 못했습니다", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("확인", role: .cancel) { model.errorMessage = nil }
                } message: { Text(model.errorMessage ?? "") }
        }.tint(.teal)
    }

    @ViewBuilder private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.definition.title).font(.headline)
            if model.isCalculating {
                ProgressView("측정 중…")
            } else if let value = model.result?.values.first {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.meters.map { String(format: "%.2f", $0 * 100) } ?? "—")
                        .font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
                        .accessibilityIdentifier("measurementValue")
                    Text("cm").font(.title2).foregroundStyle(.secondary)
                    Spacer()
                    Text(value.status.label).font(.caption.bold()).padding(8)
                        .background(value.status == .valid ? Color.teal.opacity(0.12) : Color.orange.opacity(0.12), in: Capsule())
                }
                if let failure = value.failure { Text(failure.message).font(.subheadline).foregroundStyle(.orange) }
                if value.status == .uncertain {
                    Text("깊이 또는 측정점 품질을 확인하세요. 이 값은 확정 치수로 사용하기 전에 줄자로 비교해야 합니다.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(value.points.enumerated()), id: \.offset) { index, point in
                    HStack {
                        Text(point.id == model.definition.landmarkIDs.first ? "A" : "B").fontWeight(.semibold)
                        Text(String(format: "깊이 %.3f m", point.position.z))
                        Spacer()
                        Text("표본 \(point.quality.validSamples)/\(point.quality.candidateSamples)")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text("\(point.quality.method == .localPlane ? "국소 평면" : "주변 중앙값") · 신뢰도 \(point.quality.confidenceAvailable ? "수신" : "없음")" + (point.quality.planeResidualMeters.map { String(format: " · 평면 잔차 %.1f mm", $0 * 1000) } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.labCard()
    }
}

private struct MeasurementImageView: View {
    @ObservedObject var model: MeasurementSessionModel
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = model.image { Image(uiImage: image).resizable().scaledToFill() }
                else { Color.gray.opacity(0.2) }
                Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { event in
                    model.placePoint(displayPoint: normalized(event.location, size: geometry.size), index: model.activePointIndex)
                })
                Canvas { context, size in
                    let visible = model.landmarks.points.filter(\.isVisible)
                    if visible.count == 2 {
                        let a = screen(visible[0].point, size: size), b = screen(visible[1].point, size: size)
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 5)
                        context.stroke(path, with: .color(.yellow), style: .init(lineWidth: 2, dash: [7, 4]))
                    }
                }.allowsHitTesting(false)
                ForEach(Array(model.landmarks.points.enumerated()), id: \.offset) { index, point in
                    if point.isVisible {
                        Text(index == 0 ? "A" : "B").font(.caption.bold()).foregroundStyle(.black)
                            .frame(width: 32, height: 32).background(.yellow, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 3).padding(8).contentShape(Circle())
                            .position(screen(point.point, size: geometry.size))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("measurementImage")).onChanged { value in
                                model.placePoint(displayPoint: normalized(value.location, size: geometry.size), index: index)
                            })
                            .accessibilityLabel("측정점 \(index == 0 ? "A" : "B")")
                    }
                }
            }.coordinateSpace(name: "measurementImage").clipped()
        }
    }
    private func normalized(_ p: CGPoint, size: CGSize) -> ImagePoint {
        .init(x: min(0.999999, max(0, p.x / max(1, size.width))), y: min(0.999999, max(0, p.y / max(1, size.height))))
    }
    private func screen(_ p: ImagePoint, size: CGSize) -> CGPoint {
        let display = ImageCoordinateTransform.originalToDisplay(p, orientation: model.snapshot.frame.orientation)
        return CGPoint(x: display.x * size.width, y: display.y * size.height)
    }
}

extension MeasurementStatus {
    var label: String { switch self { case .valid: "계산 완료"; case .uncertain: "확인 필요"; case .unavailable: "측정 불가" } }
}

extension MeasurementFailure {
    var message: String {
        switch self {
        case .frameMismatch: "사진과 측정점의 촬영 프레임이 다릅니다."
        case .invalidCalibration: "카메라 보정 정보와 이미지·깊이의 좌표가 맞지 않습니다."
        case .invalidDepthMap: "깊이 데이터 형식이 올바르지 않습니다."
        case .invalidMask: "의류 마스크 형식이 올바르지 않습니다."
        case .invalidOptions: "측정 설정을 확인해 주세요."
        case .invalidDefinition: "측정 항목의 시작점·끝점 정의가 올바르지 않습니다."
        case .duplicateLandmark: "같은 이름의 측정점이 중복되어 있습니다."
        case .missingLandmark: "측정에 필요한 점을 지정해 주세요."
        case .outOfBounds: "측정점이 원본 사진의 범위를 벗어났습니다."
        case .insufficientDepth: "이 점 주변에 사용할 수 있는 깊이가 부족합니다. 점과 옷의 경계를 확인해 주세요."
        case .lowLandmarkConfidence: "ML이 측정점 위치를 충분히 확신하지 못했습니다."
        case .occludedLandmark: "측정점을 지정하거나 가려진 부분이 보이도록 촬영해 주세요."
        }
    }
}
