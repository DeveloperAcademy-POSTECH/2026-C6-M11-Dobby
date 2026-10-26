//
//  HomeResumeCard.swift
//  Dobby
//
//  Created by mason on 10/27/26.
//

import SwiftUI

/// 저장·복원은 부모가 담당하고, 카드에는 표시할 단계·시간·사진만 전달합니다.
struct HomeResumeCard<Thumbnail: View>: View {
    let step: ProductDraftStep
    let savedAt: Date
    var referenceDate: Date = .now
    let onResume: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var typeScale = 1.0

    var body: some View {
        Button(action: onResume) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                description
                    .frame(maxWidth: .infinity, alignment: .leading)
                thumbnail()
                    .frame(width: 123, height: 164)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 기본 크기에서는 Figma처럼 사진 하단을 카드 경계에서 자릅니다.
            // 큰 글씨에서는 높이를 늘려 문구와 사진을 모두 확인할 수 있게 합니다.
            .frame(height: dynamicTypeSize > .large ? nil : 125, alignment: .top)
            .background(.white, in: RoundedRectangle(cornerRadius: 24))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("작업 이어서 하기, 현재 \(step.title), \(relativeSaveTime)")
        .accessibilityHint("저장된 작업 단계에서 계속합니다")
        .accessibilityIdentifier("home.resume")
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("작업 이어서 하기")
                    .font(.custom("Pretendard-SemiBold", size: 14, relativeTo: .body))
                    .foregroundStyle(.black)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
            }
            .frame(minHeight: 21 * typeScale, alignment: .leading)
            Spacer(minLength: 5 * typeScale)
            Text("현재")
                .font(.custom("Pretendard-Medium", size: 12, relativeTo: .body))
                .frame(minHeight: 18 * typeScale)
            Text(step.title)
                .font(.custom("Pretendard-Bold", size: 18, relativeTo: .body))
                .frame(minHeight: 27 * typeScale)
            Text(relativeSaveTime)
                .font(.custom("Pretendard-Medium", size: 12, relativeTo: .body))
                .foregroundStyle(Color(white: 159 / 255))
                .frame(minHeight: 18 * typeScale)
                .padding(.top, 6 * typeScale)
        }
        .foregroundStyle(Color(white: 126 / 255))
        .tracking(-0.43)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var relativeSaveTime: String {
        guard referenceDate.timeIntervalSince(savedAt) >= 60 else { return "방금 전" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: savedAt, relativeTo: referenceDate)
    }
}
