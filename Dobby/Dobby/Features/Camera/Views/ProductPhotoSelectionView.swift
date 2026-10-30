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
    let onExit: (() -> Void)?
    let onComplete: (ProductPhotoOutput) async throws -> Void
    private let onCompleteWithAI: ((ProductPhotoOutput, Bool) async throws -> Void)?
    private let onCancelGeneration: () -> Void
    private let hasProductInformation: Bool
    @Binding private var usesAI: Bool
    @State private var didComplete = false
    @State private var completionID: UUID?
    @State private var requestedAI = false
    @State private var failureMessage: String?
    @State private var isAIFailure = false
    @State private var showsReplacementConfirmation = false
    @State private var selectionLimitNoticeID: UUID?
    @State private var previewPhoto: CapturedAsset?
    private let background = Color(.systemBackground)

    init(model: ProductPhotoModel, onExit: (() -> Void)? = nil,
         usesAI: Binding<Bool> = .constant(false), hasProductInformation: Bool = false,
         onCancelGeneration: @escaping () -> Void = {},
         onCompleteWithAI: ((ProductPhotoOutput, Bool) async throws -> Void)? = nil,
         onComplete: @escaping (ProductPhotoOutput) async throws -> Void) {
        self.model = model
        self.onExit = onExit
        self.onComplete = onComplete
        _usesAI = usesAI
        self.hasProductInformation = hasProductInformation
        self.onCancelGeneration = onCancelGeneration
        self.onCompleteWithAI = onCompleteWithAI
    }

    private var completionRequested: Bool { completionID != nil }

    var body: some View {
        VStack(spacing: 12) {
            if onCompleteWithAI != nil {
                Toggle("AI로 제품 정보 입력하기", isOn: $usesAI)
                    .font(.system(size: 16, weight: .semibold))
                    .tint(ProductInformationStyle.accent)
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .accessibilityHint("켠 상태에서 다음을 누르면 선택 순서대로 최대 5장의 사진으로 제품명, 설명, 브랜드를 생성합니다")
                    .accessibilityIdentifier("product-ai.toggle")
                if usesAI && model.selectedPhotoIDs.count > 5 {
                    Text("선택한 사진 중 처음 5장으로 정보를 생성해요.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .accessibilityIdentifier("product-ai.photoLimitHint")
                }
            }
            ProductPhotoSelectionGrid(
                photos: model.photos,
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
        .navigationBarBackButtonHidden(onExit != nil)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if completionRequested {
                if requestedAI {
                    ProductAutofillLoadingView(onCancel: cancelGeneration)
                } else {
                    ProgressView("선택한 사진 저장 중").padding().background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("camera.savingPhotos")
                }
            }
        }
        .overlay { ProductPhotoSelectionNotice(requestID: $selectionLimitNoticeID) }
        .fullScreenCover(item: $previewPhoto) { photo in
            NavigationStack { ProductPhotoSelectionPreviewView(photo: photo, model: model) }
                .preferredColorScheme(.dark)
        }
        .toolbar {
            if let onExit {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onExit) {
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
                    if usesAI && hasProductInformation && onCompleteWithAI != nil {
                        showsReplacementConfirmation = true
                    } else {
                        requestCompletion(usingAI: usesAI && onCompleteWithAI != nil)
                    }
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
        .task(id: completionID) {
            guard let identifier = completionID, let output = model.output else { return }
            failureMessage = nil
            do {
                if let onCompleteWithAI {
                    try await onCompleteWithAI(output, requestedAI)
                } else {
                    try await onComplete(output)
                }
                guard completionID == identifier else { return }
                didComplete = true
            } catch {
                if completionID == identifier, !(error is CancellationError), !Task.isCancelled {
                    isAIFailure = error is ProductAutofillCompletionFailure
                    failureMessage = error.localizedDescription
                }
            }
            if completionID == identifier { completionID = nil }
        }
        .alert(isAIFailure ? "AI 정보를 생성하지 못했어요" : "사진을 저장하지 못했어요", isPresented: Binding(
            get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
        )) {
            if isAIFailure {
                Button("다시 시도") { requestCompletion(usingAI: true) }
                    .accessibilityIdentifier("product-ai.retry")
                Button("직접 입력") { requestCompletion(usingAI: false) }
                    .accessibilityIdentifier("product-ai.manual")
                Button("취소", role: .cancel) { failureMessage = nil }
            } else {
                Button("확인", role: .cancel) { failureMessage = nil }
            }
        } message: {
            Text(failureMessage ?? "사진을 다시 선택하고 다음을 눌러 주세요.")
        }
        .confirmationDialog("작성한 정보를 AI 내용으로 바꿀까요?", isPresented: $showsReplacementConfirmation,
                            titleVisibility: .visible) {
            Button("AI로 바꾸기") { requestCompletion(usingAI: true) }
                .accessibilityIdentifier("product-ai.replace")
            Button("기존 정보로 계속") { requestCompletion(usingAI: false) }
            Button("취소", role: .cancel) { }
        } message: {
            Text("제품명, 설명, 브랜드가 새로 생성됩니다. 가격과 실측 사이즈는 유지돼요.")
        }
        .onAppear { didComplete = false }
        .onDisappear {
            selectionLimitNoticeID = nil
            if completionRequested { cancelGeneration() }
        }
    }

    private func requestCompletion(usingAI: Bool) {
        guard !completionRequested, !didComplete, model.output != nil else { return }
        failureMessage = nil
        selectionLimitNoticeID = nil
        requestedAI = usingAI
        completionID = UUID()
    }

    private func cancelGeneration() {
        onCancelGeneration()
        completionID = nil
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
