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
    var productName: String? = nil
    let onResume: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        Button(action: onResume) {
            ProductDraftCard(step: step, relativeSaveTime: relativeSaveTime) {
                thumbnail()
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(accessibleProductName), 작업 이어서 하기, 현재 \(step.title)")
        .accessibilityValue("\(relativeSaveTime) 저장")
        .accessibilityHint("저장된 작업 단계에서 계속합니다")
        .accessibilityIdentifier("home.resume")
    }

    private var accessibleProductName: String {
        let name = productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "이름 없는 상품" : name
    }

    private var relativeSaveTime: String {
        guard referenceDate.timeIntervalSince(savedAt) >= 60 else { return "방금 전" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: savedAt, relativeTo: referenceDate)
    }
}
