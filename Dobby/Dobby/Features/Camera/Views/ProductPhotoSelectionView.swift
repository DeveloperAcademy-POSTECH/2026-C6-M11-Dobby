//
//  ProductPhotoSelectionView.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import SwiftUI

/// 선택 데이터와 결과는 촬영 화면의 같은 MV Model을 사용한다.
struct ProductPhotoSelectionView: View {
    let model: ProductPhotoModel
    let onBack: (() -> Void)?
    let onComplete: (ProductPhotoOutput) async throws -> Void
    @State private var didComplete = false
    @State private var completionRequested = false
    @State private var failureMessage: String?
    @State private var selectionLimitNoticeID: UUID?
    @State private var previewPhoto: CapturedAsset?
    // UI 옵션만 보관한다. 실제 AI 요청과 저장 연동은 담당 기능에서 연결한다.
    @State private var isAIInformationEnabled = true
    private let background = Color(.systemBackground)

    init(model: ProductPhotoModel, onBack: (() -> Void)? = nil,
         onComplete: @escaping (ProductPhotoOutput) async throws -> Void) {
        self.model = model
        self.onBack = onBack
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            ProductPhotoAIOptionRow(isOn: $isAIInformationEnabled)
            // 그리드 자체의 상단 4pt 여백을 사용해 옵션 행과 간격을 맞춘다.
            ProductPhotoSelectionGrid(
                photos: model.selectablePhotos,
                selectedPhotoIDs: model.selectedPhotoIDs,
                onPreview: { selectionLimitNoticeID = nil; previewPhoto = $0 },
                onToggleSelection: toggleSelection
            )
        }
        .disabled(model.isCapturing || model.isDeleting || completionRequested || didComplete)
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .tint(.primary)
        .navigationTitle("제품 사진 선택")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(onBack != nil)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if completionRequested {
                ProgressView("선택한 사진 저장 중").padding().background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("camera.savingPhotos")
            }
        }
        .overlay { ProductPhotoSelectionNotice(requestID: $selectionLimitNoticeID) }
        .fullScreenCover(item: $previewPhoto) { photo in
            NavigationStack { ProductPhotoSelectionPreviewView(photo: photo, model: model) }
                .preferredColorScheme(.dark)
        }
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                    }
                        .disabled(model.isCapturing || model.isDeleting || completionRequested || didComplete)
                        .accessibilityLabel("뒤로가기")
                        .accessibilityIdentifier("product-flow.back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard !didComplete, !completionRequested, model.output != nil else { return }
                    selectionLimitNoticeID = nil
                    completionRequested = true
                } label: {
                    Text("다음").foregroundStyle(.white)
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Color(red: 0.94, green: 0.24, blue: 0.07))
                .disabled(model.output == nil || completionRequested || didComplete)
                .accessibilityValue("\(model.selectedPhotoIDs.count)장 선택 · 최소 1장 · 최대 \(ProductPhotoModel.maximumSelectionCount)장")
                .accessibilityIdentifier("camera.completePhotos")
            }
        }
        .task(id: completionRequested) {
            guard completionRequested, let output = model.output else { return }
            failureMessage = nil
            do {
                try await onComplete(output)
                didComplete = true
            } catch {
                if !(error is CancellationError), !Task.isCancelled {
                    failureMessage = error.localizedDescription
                }
            }
            completionRequested = false
        }
        .alert("사진을 저장하지 못했어요", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
        )) {
            Button("확인", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "사진을 다시 선택하고 다음을 눌러 주세요.")
        }
        .onAppear { didComplete = false }
        .onDisappear { selectionLimitNoticeID = nil }
    }

    private func toggleSelection(_ id: UUID) {
        switch model.toggleSelection(id) {
        case .limitReached:
            selectionLimitNoticeID = UUID()
        case .updated:
            selectionLimitNoticeID = nil
        case .ignored:
            break
        }
    }
}
