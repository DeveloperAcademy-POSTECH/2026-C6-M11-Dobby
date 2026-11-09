import SwiftUI
import UIKit

/// Hosts saving progress above the camera and its navigation controls. The
/// owner supplies completed writes; this view never advances progress itself.
struct DetailPhotoLibrarySavingOverlay: View {
    let savedCount: Int
    let totalCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title3) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .title3) private var titleLineHeight: CGFloat = 29
    @ScaledMetric(relativeTo: .callout) private var messageSize: CGFloat = 16
    @ScaledMetric(relativeTo: .callout) private var messageLineHeight: CGFloat = 24
    @AccessibilityFocusState private var progressIsFocused: Bool

    private var total: Int { max(0, totalCount) }
    private var completed: Int { min(total, max(0, savedCount)) }
    private var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(358, max(0, geometry.size.width - 40))
            ZStack {
                Color.black.opacity(0.32)
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)

                ViewThatFits(in: .vertical) {
                    card(width: cardWidth)
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView {
                        card(width: cardWidth)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("camera.library-saving")
        .onAppear { progressIsFocused = true }
    }

    private func card(width: CGFloat) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                styledText("이미지를 저장할게요", fontName: "Pretendard-Bold",
                           size: titleSize, lineHeight: titleLineHeight)

                savingIndicator
                    // Figma's 24pt spinner occupies a 29pt symbol line.
                    .frame(width: 24, height: 29)
                    .padding(.vertical, 16)
                    .accessibilityHidden(true)

                styledText("조금만 기다려주세요...", fontName: "Pretendard-Regular",
                           size: messageSize, lineHeight: messageLineHeight)

                styledText("(\(completed)/\(total))", fontName: "Pretendard-Regular",
                           size: messageSize, lineHeight: messageLineHeight)
                    .monospacedDigit()
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .padding(16)
        .frame(width: width)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("이미지를 저장할게요. 조금만 기다려주세요.")
        .accessibilityValue(total > 0 ? "\(total)장 중 \(completed)장 저장 완료" : "저장 준비 중")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($progressIsFocused)
        .accessibilityIdentifier("camera.library-saving.progress")
    }

    @ViewBuilder
    private var savingIndicator: some View {
        if reduceMotion {
            ZStack {
                Circle().stroke(Color("BrandNeutral400").opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(Color("BrandNeutral400"), style: .init(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            .transaction { $0.animation = nil }
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.regular)
                .tint(Color("BrandNeutral400"))
                .scaleEffect(1.2)
        }
    }

    private func styledText(_ value: String, fontName: String, size: CGFloat,
                            lineHeight: CGFloat) -> some View {
        let font = UIFont(name: fontName, size: size) ?? UIFont.systemFont(ofSize: size)
        let adjustment = max(0, lineHeight - font.lineHeight)
        return Text(value)
            .font(.custom(fontName, fixedSize: size))
            .tracking(-size * 0.01)
            .lineSpacing(adjustment)
            .padding(.vertical, adjustment / 2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("갤러리 저장 중") {
    Color.gray.ignoresSafeArea()
        .overlay { DetailPhotoLibrarySavingOverlay(savedCount: 1, totalCount: 23) }
}

#Preview("갤러리 저장 중 · 큰 글자") {
    DetailPhotoLibrarySavingOverlay(savedCount: 10, totalCount: 23)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
