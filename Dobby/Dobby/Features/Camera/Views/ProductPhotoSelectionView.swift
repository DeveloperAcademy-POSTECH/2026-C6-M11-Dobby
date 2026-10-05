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
    let onComplete: (ProductPhotoOutput) async throws -> Void
    @State private var didComplete = false
    @State private var completionRequested = false
    @State private var failureMessage: String?
    private let background = Color(red: 26 / 255, green: 25 / 255, blue: 25 / 255)

    var body: some View {
        GeometryReader { geometry in
            // Figma 402×874: 캐러셀 421, 간격 52, 썸네일 109pt. 작은 높이에서는 사진부터 축소한다.
            let scale = min(geometry.size.width / 402, max(0, (geometry.size.height - 109) / 473))
            let freeHeight = max(0, geometry.size.height - 109 - 473 * scale)
            VStack(spacing: 0) {
                Spacer().frame(height: min(freeHeight, max(0, 177 * scale - geometry.frame(in: .global).minY)))
                ProductPhotoCarousel(photos: model.photos,
                                     representativePhotoID: model.selectedPhotoIDs.first)
                    .frame(height: 421 * scale)
                Spacer().frame(height: 52 * scale)
                ProductPhotoSelectionStrip(model: model).frame(height: 109).padding(.leading, 20)
                Spacer(minLength: 0)
            }
        }
        .disabled(model.isCapturing || completionRequested || didComplete)
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationTitle("제품 사진 선택")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if completionRequested {
                ProgressView("선택한 사진 저장 중").padding().background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("camera.savingPhotos")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard !didComplete, !completionRequested, model.output != nil else { return }
                    completionRequested = true
                } label: {
                    Text("완료").foregroundStyle(.white)
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent).tint(.blue)
                .disabled(model.output == nil || completionRequested || didComplete)
                .accessibilityValue("\(model.selectedPhotoIDs.count)장 선택 · 최소 1장")
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
            Text(failureMessage ?? "사진을 다시 선택하고 완료를 눌러 주세요.")
        }
        .onAppear { didComplete = false }
    }
}
