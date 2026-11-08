#if DEBUG
import PhotosUI
import SwiftUI
import UIKit

/// Temporary testing entry using the same generator and authentication as product creation.
struct ProductAutofillTestView: View {
    @State private var session = ProductAutofillTestSession()
    @State private var selection: [PhotosPickerItem] = []
    @State private var isLoadingSelection = false
    @State private var selectionError: String?
    @State private var selectionRun = UUID()
    @State private var didSeedFixture = false
    @State private var copied = false

    private var isFixture: Bool {
        ProductAutofillClient.fixtureMode(environment: ProcessInfo.processInfo.environment,
            isFixture: ProductAppStorage.fixtureDirectory != nil) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("앨범에서 같은 옷의 전체 사진과 라벨을 골라 생성 결과를 확인해 보세요.")
                    .font(.subheadline).foregroundStyle(.secondary)

                if isFixture {
                    Text("화면 확인용 예시 모드 · 실제 AI 호출 없음")
                        .font(.subheadline.weight(.semibold))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("ai-test.fixture")
                }

                photoSection

                VStack(spacing: 12) {
                    Button {
                        copied = false
                        selectionError = nil
                        session.start()
                    } label: {
                        Label(session.result == nil ? "AI 정보 생성하기" : "같은 사진으로 다시 생성하기",
                            systemImage: "sparkles")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.photos.isEmpty || isLoadingSelection || session.isImporting || session.isGenerating)
                    .accessibilityIdentifier("ai-test.generate")

                    if session.isGenerating {
                        ProgressView("사진을 살펴보고 제품 정보를 생성하고 있어요")
                            .font(.subheadline)
                            .accessibilityIdentifier("ai-test.loading")
                        Button("생성 취소") { session.cancel() }
                            .accessibilityIdentifier("ai-test.cancel")
                    }

                    if !isFixture {
                        Text("생성 버튼을 누르면 사진을 AI로 전송하며, 팀 API 사용량에 포함됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let error = selectionError ?? session.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                        .accessibilityIdentifier("ai-test.error")
                }

                if let result = session.result {
                    resultSection(result)
                    diagnosticsSection(result.diagnostics)
                    Button {
                        UIPasteboard.general.string = copyText(result)
                        copied = true
                    } label: {
                        Label(copied ? "결과를 복사했어요" : "결과 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("ai-test.copy")
                }
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .tint(ProductInformationStyle.accent)
        .navigationTitle("AI 정보 생성 테스트")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("초기화") {
                    selectionRun = UUID()
                    selection = []
                    isLoadingSelection = false
                    selectionError = nil
                    copied = false
                    session.clear()
                }
                .disabled(session.photos.isEmpty && !isLoadingSelection)
                .accessibilityIdentifier("ai-test.clear")
            }
        }
        .task(id: selection) { await loadSelection() }
        .task { await seedFixtureIfNeeded() }
        .onDisappear {
            selectionRun = UUID()
            selection = []
            isLoadingSelection = false
            session.clear()
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("테스트 사진").font(.headline)
                Spacer()
                Text("\(session.photos.count)/5장").font(.subheadline).foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $selection, maxSelectionCount: 5, selectionBehavior: .ordered,
                matching: .images) {
                Label(session.photos.isEmpty ? "앨범에서 사진 선택" : "사진 다시 선택", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .disabled(session.isGenerating || isLoadingSelection || session.isImporting)
            .accessibilityIdentifier("ai-test.pickPhotos")

            if isLoadingSelection || session.isImporting { ProgressView("사진을 불러오고 있어요") }
            if !session.photos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(session.photos.enumerated()), id: \.element.id) { index, photo in
                            VStack(spacing: 4) {
                                if let image = UIImage(data: photo.thumbnailData) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 100, height: 128).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .accessibilityLabel("테스트 사진 \(index + 1)")
                                        .accessibilityIdentifier("ai-test.photo.\(index)")
                                }
                                Button {
                                    selection = []
                                    copied = false
                                    session.removePhoto(photo.id)
                                } label: {
                                    Label("\(index + 1)번 삭제", systemImage: "xmark.circle")
                                        .font(.caption).frame(minHeight: 36)
                                }
                                .disabled(session.isGenerating || isLoadingSelection || session.isImporting)
                                .accessibilityIdentifier("ai-test.removePhoto.\(index)")
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
    }

    private func resultSection(_ result: ProductAutofillGenerationResult) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            resultField("제품명", value: result.draft.productName, id: "name")
            resultField("브랜드", value: result.draft.brand ?? "미확인", id: "brand")
            resultField("설명", value: result.draft.description, id: "description")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func resultField(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(value).font(.subheadline).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("ai-test.result.\(id)")
        }
    }

    private func diagnosticsSection(_ diagnostics: ProductAutofillDiagnostics?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("생성 기록").font(.headline)
            diagnosticRow("처리 시간", value: String(format: "%.1f초", session.elapsedSeconds), id: "duration")
            diagnosticRow("검색 완료", value: diagnostics.map { "\($0.searchCalls)회" } ?? "확인 불가", id: "calls")
            diagnosticRow("검색 시도", value: diagnostics.map { "\($0.searchAttempts)회" } ?? "확인 불가", id: "attempts")
            diagnosticRow("검색 결과", value: researchStatus(diagnostics), id: "status")
            if let requestID = diagnostics?.requestID {
                Text("요청 번호").font(.caption).foregroundStyle(.secondary)
                Text(requestID.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Text(diagnostics == nil ? "이 응답에는 검색 기록이 포함되지 않았어요." : "검색 결과는 찾은 정보가 제품명·브랜드·설명에 반영됐는지를 표시합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func diagnosticRow(_ title: String, value: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("ai-test.research.\(id)")
        }.font(.subheadline)
    }

    private func researchStatus(_ diagnostics: ProductAutofillDiagnostics?) -> String {
        guard let diagnostics else { return "확인 불가" }
        switch diagnostics.researchStatus {
        case .skipped: return "검색 생략"
        case .matched: return "검색 정보 반영"
        case .noMatch: return "조건에 맞는 정보 없음"
        case .incomplete: return "검색 미완료"
        }
    }

    private func copyText(_ result: ProductAutofillGenerationResult) -> String {
        let diagnostics = result.diagnostics
        var lines: [String] = []
        if isFixture { lines += ["화면 확인용 예시 · 실제 AI 호출 없음", ""] }
        lines += ["제품명: \(result.draft.productName)", "브랜드: \(result.draft.brand ?? "미확인")",
            "", "설명", result.draft.description, "",
            "처리 시간: \(String(format: "%.1f초", session.elapsedSeconds))",
            "검색 완료: \(diagnostics.map { "\($0.searchCalls)회" } ?? "확인 불가")",
            "검색 시도: \(diagnostics.map { "\($0.searchAttempts)회" } ?? "확인 불가")",
            "검색 결과: \(researchStatus(diagnostics))"]
        if let requestID = diagnostics?.requestID { lines.append("요청 번호: \(requestID.uuidString)") }
        return lines.joined(separator: "\n")
    }

    private func loadSelection() async {
        guard !selection.isEmpty else { return }
        let active = UUID()
        selectionRun = active
        isLoadingSelection = true
        selectionError = nil
        copied = false
        defer { if selectionRun == active { isLoadingSelection = false } }
        do {
            var data: [Data] = []
            for item in selection {
                try Task.checkCancellation()
                guard let photo = try await item.loadTransferable(type: Data.self) else {
                    throw ProductAutofillError.unreadablePhoto
                }
                guard photo.count <= 20 * 1024 * 1024 else { throw ProductAutofillError.photoTooLarge }
                data.append(photo)
            }
            try Task.checkCancellation()
            guard selectionRun == active else { return }
            await session.replacePhotos(data)
        } catch {
            guard !Task.isCancelled, selectionRun == active else { return }
            selectionError = "사진을 불러오지 못했어요. 다시 선택해 주세요."
        }
    }

    private func seedFixtureIfNeeded() async {
        guard !didSeedFixture, isFixture,
              ProcessInfo.processInfo.arguments.contains("--ai-test-photo-fixture") else { return }
        didSeedFixture = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 300)).image { context in
            UIColor.systemGray6.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 300))
            UIImage(systemName: "tshirt.fill")?.withTintColor(.systemIndigo, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 40, y: 50, width: 160, height: 190))
        }
        if let data = image.pngData() { await session.replacePhotos([data]) }
    }
}
#endif
