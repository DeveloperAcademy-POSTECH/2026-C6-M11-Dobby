// Created by mason on 11/9/26.
import SwiftUI

/// 삭제할 사진은 호출 화면에서 고정한다. 바깥 영역을 탭하면 삭제 없이 닫는다.
struct DetailPhotoDeleteConfirmation: View {
    let isDeleting: Bool
    let onCancel: () -> Void
    let onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric private var titleSize: CGFloat = 17
    @ScaledMetric private var bodySize: CGFloat = 16
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
                .frame(width: min(typeSize.isAccessibilitySize ? 358 : 242,
                                  max(0, geometry.size.width - 56)))
                .padding(28)
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
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("이 사진을 삭제하시겠어요?")
                    .font(.system(size: titleSize, weight: .semibold))
                    .tracking(-0.43).frame(minHeight: 22)
                    .accessibilityFocused($titleFocused)
                Text("삭제된 사진은 복구할 수 없어요")
                    .font(.custom("Pretendard-Regular", fixedSize: bodySize))
                    .tracking(-0.16).frame(minHeight: 24)
            }
            .padding(.vertical, 4)
            .multilineTextAlignment(.center)
            .foregroundStyle(.black)
            Button(action: onDelete) {
                ZStack {
                    Text("삭제하기").opacity(isDeleting ? 0 : 1)
                    if isDeleting { ProgressView().tint(Color("AccentsRed")) }
                }
                .font(.system(size: bodySize, weight: .semibold))
                .foregroundStyle(Color("AccentsRed"))
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color("BrandNeutral200"), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDeleting)
            .accessibilityLabel(isDeleting ? "사진 삭제 중" : "삭제하기")
            .accessibilityIdentifier("camera.galleryConfirmDelete")
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 2)
        }
    }
}
