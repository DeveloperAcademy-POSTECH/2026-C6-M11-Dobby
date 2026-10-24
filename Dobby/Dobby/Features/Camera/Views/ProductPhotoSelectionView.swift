//
//  ProductPhotoSelectionView.swift
//  Dobby
//
//  Created by mason on 9/30/26.
//

import SwiftUI
import UIKit

/// 선택 데이터와 결과는 촬영 화면의 같은 MV Model을 사용한다.
struct ProductPhotoSelectionView: View {
    let model: ProductPhotoModel
    let onComplete: (ProductPhotoOutput) async throws -> Void
    @State private var didComplete = false
    @State private var completionRequested = false
    @State private var failureMessage: String?
    @State private var selectionLimitNoticeID: UUID?
    private let background = Color(.systemBackground)
    private let selectionLimitMessage = "사진은 최대 \(ProductPhotoModel.maximumSelectionCount)개까지 선택할 수 있습니다."

    var body: some View {
        ProductPhotoSelectionGrid(
            photos: model.photos,
            selectedPhotoIDs: model.selectedPhotoIDs,
            onToggleSelection: toggleSelection
        )
        .disabled(model.isCapturing || model.isDeleting || completionRequested || didComplete)
        .background(background.ignoresSafeArea())
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .tint(.primary)
        .navigationTitle("제품 사진 선택")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if completionRequested {
                ProgressView("선택한 사진 저장 중").padding().background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("camera.savingPhotos")
            }
        }
        .overlay {
            if selectionLimitNoticeID != nil {
                Text(selectionLimitMessage)
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .frame(maxWidth: 302, minHeight: 50)
                    .background(Color(white: 23 / 255), in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1) }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("camera.selectionLimitNotice")
            }
        }
        .task(id: selectionLimitNoticeID) {
            guard let noticeID = selectionLimitNoticeID else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard selectionLimitNoticeID == noticeID else { return }
            selectionLimitNoticeID = nil
        }
        .toolbar {
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
            UIAccessibility.post(notification: .announcement, argument: selectionLimitMessage)
        case .updated:
            selectionLimitNoticeID = nil
        case .ignored:
            break
        }
    }
}
