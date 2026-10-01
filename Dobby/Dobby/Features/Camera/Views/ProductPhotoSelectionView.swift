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
    @State private var inspectedPhoto: CapturedAsset?
    @State private var didComplete = false
    @State private var completionRequested = false
    @State private var failureMessage: String?

    var body: some View {
        List {
            Section {
                Text("사용할 사진을 선택해 주세요.").font(.headline)
                Text("\(model.selectedPhotoIDs.count)장 선택 · 최소 1장")
                    .accessibilityIdentifier("camera.selectedPhotoCount")
                Text("먼저 선택한 사진이 대표 사진입니다. 선택을 해제해도 원본은 삭제되지 않아요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if completionRequested {
                    ProgressView("선택한 사진 저장 중")
                        .accessibilityIdentifier("camera.savingPhotos")
                }
            }
            if !model.selectedPhotoIDs.isEmpty {
                Section("선택 순서 · 첫 사진이 대표 사진") {
                    ForEach(model.selectedPhotoIDs, id: \.self) { id in
                        if let photo = model.photos.first(where: { $0.id == id }) {
                            HStack(spacing: 12) {
                                CameraPhotoView(source: photo.source, maximumPixelSize: 160)
                                    .frame(width: 44, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityHidden(true)
                                Text(photo.purpose == .measurement ? "실측 사진" : "상세 사진")
                                Spacer()
                                if id == model.selectedPhotoIDs.first {
                                    Text("대표").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onMove(perform: model.moveSelection)
                }
            }
            Section("사용할 사진") {
                ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                    let order = model.selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 }
                    ProductPhotoChoice(photo: photo, index: index, order: order,
                        toggle: { model.toggleSelection(photo.id) }, inspect: { inspectedPhoto = photo })
                }
            }
        }
        .disabled(model.isCapturing || completionRequested || didComplete)
        .navigationTitle("제품 사진 선택")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(model.selectedPhotoIDs.count < 2 || completionRequested || didComplete)
                    .accessibilityIdentifier("camera.reorderPhotos")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("완료") {
                    guard !didComplete, !completionRequested, model.output != nil else { return }
                    completionRequested = true
                }
                .disabled(model.output == nil || completionRequested || didComplete)
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
        .sheet(item: $inspectedPhoto) { photo in
            NavigationStack {
                CameraPhotoView(source: photo.source, maximumPixelSize: 2400, contentMode: .fit)
                    .background(.black)
                    .accessibilityLabel("상품 사진 크게 보기")
                    .navigationTitle("사진 크게 보기")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("닫기") { inspectedPhoto = nil }
                        }
                    }
            }
        }
    }
}

/// 행 전체의 선택과 크게 보기 버튼을 분리해 사진 확인 중 선택이 바뀌지 않게 한다.
private struct ProductPhotoChoice: View {
    let photo: CapturedAsset
    let index: Int
    let order: Int?
    let toggle: () -> Void
    let inspect: () -> Void
    @State private var imageAvailable: Bool?

    private var title: String { photo.purpose == .measurement ? "실측 사진" : "상세 사진 \(index)" }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    CameraPhotoView(source: photo.source, maximumPixelSize: 480, contentMode: .fit,
                                    onLoad: { imageAvailable = $0 })
                        .frame(width: 96, height: 128)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.headline)
                        Text(order.map { $0 == 1 ? "1 · 대표 사진" : "\($0)번째 선택" } ?? "선택 안 됨")
                            .font(.subheadline).foregroundStyle(order == nil ? Color.secondary : Color.accentColor)
                        if imageAvailable == false {
                            Text("사진을 불러올 수 없어요.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: order == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(order == nil ? Color.secondary : Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            // 읽기 실패한 새 사진은 선택하지 않는다. 기존 선택은 해제할 수 있다.
            .disabled(imageAvailable != true && order == nil)
            .accessibilityLabel(title)
            .accessibilityIdentifier("camera.photo.\(index)")
            .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
            .accessibilityAddTraits(order == nil ? [] : .isSelected)
            .accessibilityHint("선택하거나 선택을 해제합니다. 원본은 삭제되지 않습니다.")
            Button(action: inspect) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
            }
            .disabled(imageAvailable != true)
            .accessibilityLabel("\(title) 크게 보기")
            .accessibilityIdentifier("camera.inspectPhoto.\(index)")
        }
        .buttonStyle(.plain)
    }
}
