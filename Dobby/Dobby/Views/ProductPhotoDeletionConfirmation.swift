import SwiftUI
import UIKit

/// Matches the compact confirmation anchored over the photo's trash button.
struct ProductPhotoDeletionConfirmation: View {
    let onDelete: () -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var messageFontSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var buttonHeight: CGFloat = 54

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("이 사진을 삭제하시겠어요?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityModalHeading()
                    .accessibilityHint("동작 메뉴에서 삭제 취소를 선택하거나 두 손가락으로 문질러 닫을 수 있어요")
                    .accessibilityAction(named: "삭제 취소") { onCancel() }

                message
            }
            .foregroundStyle(.black)
            .padding(.vertical, 4)

            Button(role: .destructive, action: onDelete) {
                Text("삭제하기")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color("AccentsRed"))
                    .frame(maxWidth: .infinity, minHeight: buttonHeight)
                    .contentShape(Capsule())
                    .background(Color("BrandNeutral200"), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("product-gallery.confirm-delete")
            .accessibilityHint("현재 사진을 제품 사진 목록에서 삭제합니다")
        }
        .padding(16)
        .frame(maxWidth: 242)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("product-gallery.delete-confirmation")
        .accessibilityAction(.escape, onCancel)
    }

    private var message: some View {
        let font = UIFont(name: "Pretendard-Regular", size: messageFontSize)
            ?? UIFont.systemFont(ofSize: messageFontSize)
        let adjustment = max(0, messageLineHeight - font.lineHeight)

        return Text("삭제된 사진은 복구할 수 없어요")
            .font(.custom("Pretendard-Regular", fixedSize: messageFontSize))
            .tracking(-messageFontSize * 0.01)
            .lineSpacing(adjustment)
            .padding(.vertical, adjustment / 2)
            .lineLimit(dynamicTypeSize > .large ? nil : 1)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("제품 사진 삭제 확인") {
    Color.gray.ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            ProductPhotoDeletionConfirmation(onDelete: {}, onCancel: {})
                .padding(10)
        }
}
#endif
