import SwiftUI

struct MeasurementValidationReportView: View {
    let archive: MeasurementArchive
    @Environment(\.dismiss) private var dismiss
    @State private var validation: MeasurementValidationReport?
    @State private var attempts: MeasurementAttemptReport?
    @State private var csvURL: URL?
    @State private var markdownURL: URL?
    @State private var attemptsURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("거리 엔진과 자동 측정을 구분해 검증합니다").font(.title2.bold())
                    Text("합성 테스트는 실물 정확도에서 제외합니다. 같은 촬영을 여러 번 저장해도 독립 표본이 늘어나지 않습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if isLoading { ProgressView("기록을 다시 계산하는 중…") }
                    if let validation {
                        Text(validation.statusSummary).font(.headline).accessibilityIdentifier("validationStatus")
                        if validation.samples.isEmpty {
                            Label("실물 검증 기록 없음 · 인수 판정 대기", systemImage: "ruler")
                                .accessibilityIdentifier("validationEmpty")
                        }
                        validationMetrics(validation.manual, title: "수동점 · 거리 엔진")
                        validationMetrics(validation.automated, title: "모델점 · 자동 측정")
                        Text(MeasurementValidationCriteria.description).font(.caption).foregroundStyle(.secondary)
                        Text("기기·소재·거리 조건을 합친 위 수치만으로 지원 범위를 결정하지 않습니다. 아래 조건별 기록과 실패율을 함께 확인하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(validation.groups) { group in
                            DisclosureGroup("\(group.title) · \(group.key.track.title) · \(group.statistics.attempts)건") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text([group.key.deviceModel ?? "기기 미기록", group.key.categoryTitle,
                                          group.key.specimenName ?? "물체 미기록", group.key.conditions ?? "조건 미기록"].joined(separator: " · "))
                                    Text(group.assessment.title).fontWeight(.semibold)
                                    Text("오차 비교 \(group.statistics.compared)건 · MAE \(cm(group.statistics.meanAbsoluteErrorCentimeters)) · P95 \(cm(group.statistics.percentile95AbsoluteErrorCentimeters))")
                                    Text("반복 수치 \(group.repetitionCount)건 · 범위 \(cm(group.repeatedMeasurementRangeCentimeters)) · 표준편차 \(cm(group.repeatedMeasurementStandardDeviationCentimeters))")
                                }.font(.caption).padding(.top, 8)
                            }.labCard()
                        }
                        Text("같은 프레임의 수동/자동 비교 \(validation.counts.pairedComparisons)건 · 한쪽 측정 불가 \(validation.counts.pairedUnavailable)건 · 입력 불일치 \(validation.counts.pairMismatches)건")
                            .font(.caption)
                        Text("자동−수동 편차는 두 점 선택 방식의 차이이며 줄자 정답에 대한 오차와 다릅니다. 항목별 편차는 CSV·마크다운에 포함합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("제외: 합성 \(validation.counts.syntheticRecords)건 · 모델 정보 누락 \(validation.counts.modelMetadataMissingRecords)건 · 중복 항목 \(validation.counts.duplicateSamples)건 · 파일/형식 오류 \(validation.counts.malformedRecords)건")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let csvURL { ShareLink("검증 CSV", item: csvURL) }
                            if let markdownURL { ShareLink("검증 마크다운", item: markdownURL) }
                        }.buttonStyle(.bordered)
                    }
                    if let attempts {
                        Text("셔터부터 남기는 시도 기록").font(.title3.bold())
                        Text("사진이 나오기 전의 실패도 포함합니다. 수동 검증은 촬영까지, 자동 측정은 촬영·ML·계산 전체를 한 시도로 기록합니다.")
                            .font(.caption).foregroundStyle(.secondary)
                        attemptMetrics(attempts.manualSensor, title: "수동 검증용 촬영")
                        attemptMetrics(attempts.automaticModel, title: "자동 측정 전체")
                        if attempts.physical.totalAttempts == 0 {
                            Text("실기기 시도 기록 없음").foregroundStyle(.secondary).accessibilityIdentifier("physicalAttemptsEmpty")
                        }
                        Text("실측에서 제외한 합성 시도 \(attempts.synthetic.totalAttempts)건 · 읽기 오류 \(attempts.unreadableRecordCount)건")
                            .font(.caption).foregroundStyle(.secondary)
                        if attempts.scanLimitReached {
                            Text("읽기 상한에 도달해 전체 기록 중 일부만 표시합니다.").font(.caption).foregroundStyle(.orange)
                        }
                        if let attemptsURL { ShareLink("시도·처리시간 CSV", item: attemptsURL).buttonStyle(.bordered) }
                    }
                    Text("현재 실제 카메라·의류 ML의 팀 통합, iPhone 17 Pro 실측 오차 및 발열·메모리 평가는 별도 인수 항목입니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("최종 검증 · 시도 기록").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.disabled(isLoading) }
                    ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
                }
                .task { await reload() }
                .alert("보고서 확인", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                    Button("확인", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        }.tint(.teal)
    }

    private func validationMetrics(_ statistics: MeasurementValidationStatistics, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("항목 시도 \(statistics.attempts) · 수치 산출 \(statistics.numericResults) · 확인 필요 \(statistics.uncertain) · 측정 불가 \(statistics.unavailable)")
            Text("줄자 비교 \(statistics.compared)/\(statistics.referencedAttempts) · MAE \(cm(statistics.meanAbsoluteErrorCentimeters)) · P95 \(cm(statistics.percentile95AbsoluteErrorCentimeters))")
            Text("평균 편향 \(cm(statistics.meanSignedErrorCentimeters))")
        }.font(.caption).labCard()
    }

    private func attemptMetrics(_ value: MeasurementAttemptStatistics, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("전체 \(value.totalAttempts) · 완료 \(value.successfulAttempts) · 부분 결과 \(value.partialAttempts) · 실패 \(value.failureCount) · 취소 \(value.cancellations) · 미완료 \(value.unfinishedAttempts)")
            Text("촬영 실패 \(value.captureFailures) · 측정점 실패 \(value.landmarkFailures) · 시간 초과 \(value.timeouts) · 중단 \(value.interruptions)")
            if let rate = value.geometrySuccessRateExcludingCancellations {
                Text(String(format: "전체 항목 계산 완료율 %.1f%% (취소 제외, 실제 정확도 아님)", rate * 100))
            }
            Text("완료한 단계의 중앙값 / P95")
            Text("촬영 \(seconds(value.captureLatency.medianSeconds)) / \(seconds(value.captureLatency.p95Seconds)) · 점 추출 \(seconds(value.landmarksLatency.medianSeconds)) / \(seconds(value.landmarksLatency.p95Seconds))")
            Text("계산 \(seconds(value.measurementLatency.medianSeconds)) / \(seconds(value.measurementLatency.p95Seconds))")
            Text("종료 시도 전체 시간 \(seconds(value.totalLatency.medianSeconds)) / \(seconds(value.totalLatency.p95Seconds))")
            Text("실패한 단계의 대기시간은 단계 완료 속도에 섞지 않습니다. 미완료는 앱 종료 등으로 결과가 기록되지 않은 시도이며 자동으로 성공·실패 처리하지 않습니다.")
                .foregroundStyle(.secondary)
        }.font(.caption.monospacedDigit()).labCard()
    }

    private func cm(_ value: Double?) -> String { value.map { String(format: "%.2f cm", $0) } ?? "—" }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.3f초", $0) } ?? "—" }

    private func reload() async {
        guard !isLoading else { return }
        isLoading = true
        csvURL = nil; markdownURL = nil; attemptsURL = nil
        defer { isLoading = false }
        do {
            let report = try await archive.validationReport()
            try Task.checkCancellation()
            validation = report
            csvURL = try await archive.exportValidation(report, markdown: false)
            markdownURL = try await archive.exportValidation(report, markdown: true)
            attempts = try await LiDARAppServices.attemptJournal.report()
            attemptsURL = try await LiDARAppServices.attemptJournal.exportCSV()
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }
}
