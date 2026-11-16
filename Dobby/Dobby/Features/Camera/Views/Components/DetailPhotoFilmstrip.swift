// Created by mason on 10/23/26.
import SwiftUI

/// 스크롤 간격은 고정하고 강조 표현만 펼쳐, 크기 변경이 탐색 위치를 흔들지 않게 한다.
struct DetailPhotoFilmstrip<Thumbnail: View>: View {
    let ids: [String]
    @Binding var focusedID: String
    let width: CGFloat
    @ViewBuilder var thumbnail: (Int) -> Thumbnail
    @State private var position = ScrollPosition(x: 0)
    @State private var isUserScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let step: CGFloat = 22
    private var focusedIndex: Int { ids.firstIndex(of: focusedID) ?? 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, _ in
                    thumbnail(index)
                        .offset(x: index == focusedIndex ? 0 : index < focusedIndex ? -6 : 6)
                        .frame(width: step, height: 44)
                        .zIndex(index == focusedIndex ? 1 : 0)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: focusedID)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: ids)
            .padding(.horizontal, max(0, (width - step) / 2))
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.trailing)
        .scrollTargetBehavior(FilmstripSnap(step: step, count: ids.count))
        .onScrollPhaseChange { _, phase, context in
            switch phase {
            case .tracking, .interacting, .decelerating: isUserScrolling = true
            case .idle:
                if isUserScrolling { focus(at: Int((context.geometry.contentOffset.x / step).rounded())) }
                isUserScrolling = false
            default: isUserScrolling = false
            }
        }
        .onScrollGeometryChange(for: Int.self) {
            Int(($0.contentOffset.x / step).rounded())
        } action: { _, index in
            if isUserScrolling { focus(at: index) }
        }
        .onChange(of: width, initial: true) { _, _ in align(animated: false) }
        .onChange(of: ids) { previousIDs, _ in
            isUserScrolling = false
            if let selection = DetailPhotoGalleryPageSelection(focusedID: focusedID,
                currentID: focusedID, previousIDs: previousIDs, ids: ids), selection.id != focusedID {
                focusedID = selection.id
            }
            align(animated: true)
        }
        .onChange(of: focusedID) { _, _ in
            if !isUserScrolling { align(animated: true) }
        }
        .frame(height: 44)
        .accessibilityIdentifier("camera.galleryStrip")
    }

    private func focus(at index: Int) {
        guard !ids.isEmpty else { return }
        let id = ids[min(max(index, 0), ids.count - 1)]
        if focusedID != id { focusedID = id }
    }

    private func align(animated: Bool) {
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
            position.scrollTo(x: CGFloat(focusedIndex) * step)
        }
    }
}

private struct FilmstripSnap: ScrollTargetBehavior {
    let step: CGFloat
    let count: Int
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let index = min(max((target.rect.minX / step).rounded(), 0), CGFloat(max(0, count - 1)))
        target.rect.origin.x = index * step
    }
}
