//
//  ProductPhotoSelectionStrip.swift
//  Dobby
//
//  Created by mason on 10/4/26.
//

import SwiftUI

/// 선택 순서 + 미선택 촬영 순서. 탐색 위치와 대표 사진은 각각 별도로 관리한다.
struct ProductPhotoSelectionStrip: View {
    let model: ProductPhotoModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var holding = false
    @State private var draggedID: UUID?
    @State private var resolvedDragSource = false
    @State private var pointer = CGPoint.zero
    @State private var frames: [UUID: CGRect] = [:]
    @State private var viewport = CGRect.zero
    @State private var scroll = ScrollPosition(x: 0)
    @State private var scrollX: CGFloat = 0
    @State private var ignoreTapUntil = Date.distantPast

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.selectionOrderedPhotos) { photo in
                    ProductPhotoSelectionThumbnail(photo: photo,
                        order: model.selectedPhotoIDs.firstIndex(of: photo.id).map { $0 + 1 },
                        captureIndex: model.photos.firstIndex(where: { $0.id == photo.id }) ?? 0,
                        toggle: { if !holding && Date.now > ignoreTapUntil { model.toggleSelection(photo.id) } })
                        .opacity(draggedID == photo.id ? 0.3 : 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            frames[photo.id] = $0
                        }
                        .accessibilityActions {
                            if let index = model.selectedPhotoIDs.firstIndex(of: photo.id) {
                                if index > 0 { Button("앞으로 이동") { move(photo.id, to: index - 1) } }
                                if index + 1 < model.selectedPhotoIDs.count {
                                    Button("뒤로 이동") { move(photo.id, to: index + 1) }
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .animation(reduceMotion || holding ? nil : .easeInOut(duration: 0.2), value: model.selectedPhotoIDs)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
        .scrollDisabled(draggedID != nil)
        .simultaneousGesture(reorderGesture)
        .overlay(alignment: .topLeading) {
            if let photo = model.photos.first(where: { $0.id == draggedID }) {
                CameraPhotoView(source: photo.source, maximumPixelSize: 320)
                    .frame(width: 60.5, height: 84.7).scaleEffect(1.08)
                    .offset(x: pointer.x - viewport.minX - 30.25, y: pointer.y - viewport.minY - 42.35)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: holding) { _, active in
            if !active { draggedID = nil; resolvedDragSource = false }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { draggedID = nil } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { draggedID = nil } }
        .task(id: draggedID) {
            while draggedID != nil && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard draggedID != nil, isEnabled, scenePhase == .active else { return }
                autoScrollAndReorder()
            }
        }
        .background(Color(.tertiaryLabel), in: RoundedRectangle(cornerRadius: 16))
        .disabled(model.isCapturing)
        .accessibilityIdentifier("camera.selectionStrip")
    }

    private var reorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($holding) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard isEnabled, !model.isCapturing, case .second(true, let drag) = value else { return }
                ignoreTapUntil = .now.addingTimeInterval(0.3)
                guard let drag else { return }
                // 시작 사진만 판정해 미선택 사진의 스크롤이 다른 사진 드래그로 바뀌지 않게 한다.
                if !resolvedDragSource {
                    resolvedDragSource = true
                    draggedID = model.selectedPhotoIDs.first { frames[$0]?.contains(drag.startLocation) == true }
                }
                pointer = drag.location
                reorderAtPointer()
            }
            .onEnded { _ in
                ignoreTapUntil = .now.addingTimeInterval(0.3)
                draggedID = nil
                resolvedDragSource = false
            }
    }

    private func move(_ id: UUID, to target: Int) {
        guard let from = model.selectedPhotoIDs.firstIndex(of: id), from != target else { return }
        model.moveSelection(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
    }

    private func reorderAtPointer() {
        guard let id = draggedID, viewport.contains(pointer) else { return }
        let ids = model.selectedPhotoIDs
        if let target = ids.indices.min(by: {
            abs((frames[ids[$0]]?.midX ?? .infinity) - pointer.x) < abs((frames[ids[$1]]?.midX ?? .infinity) - pointer.x)
        }) { move(id, to: target) }
    }

    private func autoScrollAndReorder() {
        guard viewport.contains(pointer) else { return }
        let direction: CGFloat = pointer.x < viewport.minX + 30 ? -1 : (pointer.x > viewport.maxX - 30 ? 1 : 0)
        // 미선택 영역까지 끌고 가지 않고 선택 그룹의 양 끝에서 멈춘다.
        let end = model.selectedPhotoIDs.compactMap { frames[$0]?.maxX }.max() ?? viewport.maxX
        let limit = max(0, end - viewport.maxX + scrollX + 16)
        if direction != 0 { scroll.scrollTo(x: min(limit, max(0, scrollX + direction * 8))) }
        reorderAtPointer()
    }
}

private struct ProductPhotoSelectionThumbnail: View {
    let photo: CapturedAsset
    let order: Int?
    let captureIndex: Int
    let toggle: () -> Void
    @State private var imageAvailable: Bool?
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 10.0
    private let orange = Color(red: 247 / 255, green: 96 / 255, blue: 21 / 255)

    var body: some View {
        Button(action: toggle) {
            CameraPhotoView(source: photo.source, maximumPixelSize: 320,
                            onLoad: { imageAvailable = $0 })
                .frame(width: 60.5, height: 84.7)
                .overlay(alignment: .topLeading) {
                    if photo.purpose == .measurement {
                        Text("실측샷").foregroundStyle(orange)
                            .padding(.horizontal, 6).padding(.vertical, 4).background(.white)
                            .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 6)).padding(2)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let order {
                        Text("\(order)").foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 4).background(.black)
                            .clipShape(UnevenRoundedRectangle(topTrailingRadius: 6)).padding(2)
                    }
                }
                .overlay { Rectangle().strokeBorder(order == nil ? .clear : orange, lineWidth: 2) }
                .font(.system(size: badgeSize, weight: .semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 손상된 새 사진은 선택하지 않되 이미 선택한 사진은 해제할 수 있다.
        .disabled(imageAvailable != true && order == nil)
        .accessibilityLabel(photo.purpose == .measurement ? "실측 사진" : "상세 사진 \(captureIndex)")
        .accessibilityValue(order.map { "\($0)번째 선택" } ?? "선택 안 됨")
        .accessibilityHint(imageAvailable == false ? "사진을 불러올 수 없어요" : "탭하여 선택 또는 해제. 선택 사진은 길게 눌러 순서를 바꿀 수 있어요. 첫 사진이 대표입니다.")
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
        .accessibilityIdentifier("camera.thumbnail.\(captureIndex)")
    }
}
