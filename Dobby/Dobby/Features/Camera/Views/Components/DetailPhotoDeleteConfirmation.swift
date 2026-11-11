// Created by mason on 11/9/26.
import SwiftUI

/// 삭제할 사진은 호출 화면에서 고정한다. 바깥 영역을 탭하면 삭제 없이 닫는다.
struct DetailPhotoDeleteConfirmation: View {
    let isDeleting: Bool
    let bottomInset: CGFloat
    let onCancel: () -> Void
    let onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var titleSize: CGFloat = 17
    @ScaledMetric private var bodySize: CGFloat = 17
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if !isDeleting { onCancel() } }
                    .accessibilityHidden(true)
                ViewThatFits(in: .vertical) {
                    panel.fixedSize(horizontal: false, vertical: true)
                    ScrollView { panel }.scrollBounceBehavior(.basedOnSize)
                }
                .frame(width: min(typeSize.isAccessibilitySize ? 358 : 300,
                                  max(0, geometry.size.width - 40)))
                .padding(.trailing, 20)
                .padding(.top, 16)
                .padding(.bottom, max(0, bottomInset))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { if !isDeleting { onCancel() } }
        .accessibilityIdentifier("camera.galleryDeleteConfirmation")
        .onAppear { titleFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("이 사진을 삭제하시겠어요?")
                    .font(.system(size: titleSize, weight: .semibold))
                    .tracking(-0.43)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .accessibilityFocused($titleFocused)
                Text("삭제된 사진은 복구할 수 없어요")
                    .font(.system(size: bodySize, weight: .regular))
                    .tracking(-0.43)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .multilineTextAlignment(.leading)
            .foregroundStyle(.black)
            Button(action: onDelete) {
                ZStack {
                    Text("삭제하기").opacity(isDeleting ? 0 : 1)
                    if isDeleting { ProgressView().tint(Color("AccentsRed")) }
                }
                .font(.system(size: bodySize, weight: .semibold))
                .tracking(-0.43)
                .foregroundStyle(Color("AccentsRed"))
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(uiColor: .secondarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityLabel(isDeleting ? "사진 삭제 중" : "삭제하기")
            .accessibilityIdentifier("camera.galleryConfirmDelete")
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
            shape.fill(.clear)
                .glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        }
        // 글라스의 문구·여백 탭이 뒤쪽 취소 영역으로 전달되지 않게 한다.
        .contentShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .onTapGesture {}
    }
}
