import SwiftUI

struct BaselineReportView: View {
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss
    @State private var report: BaselineReport?
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("실제 센서의 오차를 확인합니다").font(.title2.bold())
                    Text("실촬영 사진에서 직접 지정한 점을 같은 조건으로 다시 계산합니다. 합성 데모와 ML 측정점은 이 거리 엔진 기준선에서 제외합니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isLoading { ProgressView("저장 기록을 비교하는 중…") }
                    if let report {
                        if report.samples.isEmpty {
                            Label("실측 기록 없음 · 검증 대기", systemImage: "ruler")
                                .font(.headline).accessibilityIdentifier("baselineEmpty")
                            Text("LiDAR로 촬영한 뒤 A/B점과 줄자 기준값을 입력하고 저장하세요. 지금 표시할 실제 정확도 수치는 없습니다.")
                                .foregroundStyle(.secondary)
                        } else {
                            metrics(report)
                            pairedMetrics(report)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("집계 기준").font(.headline)
                            Text("서로 다른 촬영·항목 \(report.samples.count)건")
                            Text("제외: 합성 \(report.syntheticRecords)건 · 수동점 이외 \(report.nonManualRecords)건 · 중복 저장 \(report.duplicateSaves)건 · 읽기/형식 오류 \(report.malformedRecords)건")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("같은 프레임·항목은 가장 최근 저장만 사용합니다. 실패 기록은 전체 시도 수에 남고, 줄자값이나 측정값이 없으면 오차는 계산하지 않습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.labCard()
                        if !report.samples.isEmpty {
                            Text("수치는 기기·옷·촬영 조건이 섞인 탐색용 집계입니다. CSV에서 조건별로 나눠 확인하세요. ‘확인 필요’ 수치도 오차 계산에 포함하며, 측정 실패는 별도로 표시합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let exportURL {
                                ShareLink(item: exportURL) { Label("비교 기록 CSV 공유", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        Text("다음 실측: 같은 물체·끝점을 정면/기울기와 거리별로 각각 3회 이상 새로 촬영하고, 물체 이름과 촬영 조건을 기록하세요.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("실측 비교 보고서").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading)
                            .accessibilityLabel("실측 보고서 새로고침")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
                }
                .task { await reload() }
                .alert("보고서를 불러오지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("확인", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.teal)
    }

    private func metrics(_ report: BaselineReport) -> some View {
        let a = report.baseline, b = report.stabilized
        return VStack(alignment: .leading, spacing: 14) {
            Text("같은 촬영 기록으로 비교").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow { Text("항목"); Text("기본"); Text("깊이 안정화") }.font(.caption.bold())
                GridRow { Text("수치 산출"); Text("\(a.numericResults)/\(a.attempts)"); Text("\(b.numericResults)/\(b.attempts)") }
                GridRow { Text("품질 기준 충족"); Text("\(a.valid)/\(a.attempts)"); Text("\(b.valid)/\(b.attempts)") }
                GridRow { Text("확인 필요"); Text("\(a.uncertain)"); Text("\(b.uncertain)") }
                GridRow { Text("측정 불가"); Text("\(a.unavailable)"); Text("\(b.unavailable)") }
                GridRow { Text("오차 비교 수"); Text("\(a.compared)/\(a.referencedAttempts)"); Text("\(b.compared)/\(b.referencedAttempts)") }
                GridRow { Text("평균 절대오차"); Text(cm(a.meanAbsoluteErrorCentimeters)); Text(cm(b.meanAbsoluteErrorCentimeters)) }
                GridRow { Text("큰 오차(P95)"); Text(cm(a.percentile95AbsoluteErrorCentimeters)); Text(cm(b.percentile95AbsoluteErrorCentimeters)) }
                GridRow { Text("평균 편향"); Text(cm(a.meanSignedErrorCentimeters)); Text(cm(b.meanSignedErrorCentimeters)) }
            }.font(.caption.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
            Text("기본 모드는 이상치 제거 후 주변 중앙값을 사용합니다. 이 모드는 보수적으로 ‘확인 필요’로 표시하며, 수치가 나온 비율과 품질 기준 충족을 구분합니다.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("알고리즘 \(report.algorithmVersion) · ±값은 앱 치수 − 줄자 치수입니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }.labCard()
    }

    private func cm(_ value: Double?) -> String { value.map { String(format: "%.2f cm", $0) } ?? "—" }

    private func pairedMetrics(_ report: BaselineReport) -> some View {
        let raw = report.pairedRaw, smoothed = report.pairedSmoothed
        return VStack(alignment: .leading, spacing: 14) {
            Text("원본 깊이와 평활화 깊이 비교").font(.headline)
            Text("같은 촬영 프레임에서 두 깊이 지도가 모두 저장된 기록만 비교합니다. 양쪽 모두 동일한 측정점·설정으로 국소 평면 계산을 적용합니다.")
                .font(.caption).foregroundStyle(.secondary)
            if raw.attempts == 0 {
                Label("동일 프레임 깊이 쌍 없음 · 비교 대기", systemImage: "square.stack.3d.up")
                    .font(.subheadline.bold()).accessibilityIdentifier("pairedBaselineEmpty")
                Text("원본 깊이만 있는 이전 기록은 위 집계에 그대로 남습니다. 두 깊이가 함께 저장되는 새 촬영 기록부터 이 비교에 포함됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow { Text("항목"); Text("원본 깊이"); Text("평활화 깊이") }.font(.caption.bold())
                    GridRow { Text("공통 시도 수"); Text("\(raw.attempts)"); Text("\(smoothed.attempts)") }
                    GridRow { Text("수치 산출"); Text("\(raw.numericResults)/\(raw.attempts)"); Text("\(smoothed.numericResults)/\(smoothed.attempts)") }
                    GridRow { Text("품질 기준 충족"); Text("\(raw.valid)/\(raw.attempts)"); Text("\(smoothed.valid)/\(smoothed.attempts)") }
                    GridRow { Text("확인 필요"); Text("\(raw.uncertain)"); Text("\(smoothed.uncertain)") }
                    GridRow { Text("측정 불가"); Text("\(raw.unavailable)"); Text("\(smoothed.unavailable)") }
                    GridRow { Text("공통 오차 비교 수"); Text("\(raw.compared)/\(raw.referencedAttempts)"); Text("\(smoothed.compared)/\(smoothed.referencedAttempts)") }
                    GridRow { Text("평균 절대오차"); Text(cm(raw.meanAbsoluteErrorCentimeters)); Text(cm(smoothed.meanAbsoluteErrorCentimeters)) }
                    GridRow { Text("큰 오차(P95)"); Text(cm(raw.percentile95AbsoluteErrorCentimeters)); Text(cm(smoothed.percentile95AbsoluteErrorCentimeters)) }
                    GridRow { Text("평균 편향"); Text(cm(raw.meanSignedErrorCentimeters)); Text(cm(smoothed.meanSignedErrorCentimeters)) }
                }.font(.caption.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
                Text("실패는 공통 시도 수에 유지합니다. 오차 수치는 줄자값이 있고 양쪽 모두 수치가 나온 같은 기록으로만 계산하므로, 위 전체 기록의 오차와 표본 수가 다를 수 있습니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("깊이 쌍 제외: 평활화 깊이 없음 \(report.missingCompanionRecords)건 · 프레임/형식 불일치 \(report.mismatchedCompanionRecords)건")
                .font(.caption).foregroundStyle(.secondary)
            Text("평활화는 여러 시점의 깊이를 반영하므로 움직임의 영향이 다를 수 있습니다. 실측 비교 전에는 어느 방식이 더 정확한지 판단하지 않습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }.labCard()
    }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        exportURL = nil
        defer { isLoading = false }
        do {
            let value = try await archive.baselineReport()
            try Task.checkCancellation()
            report = value
            if !value.samples.isEmpty { exportURL = try await archive.exportBaselineCSV(value) }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}
