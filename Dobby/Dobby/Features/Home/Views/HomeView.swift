//
//  HomeView.swift
//  Dobby
//
//  Created by mason on 10/5/26.
//

import SwiftUI

/// 홈 콘텐츠만 담당합니다. 탭·촬영 화면 전환은 부모가 소유합니다.
struct HomeView: View {
    var resumeCandidate: HomeResumeCandidate? = nil
    var onResumeDraft: ((UUID) -> Void)? = nil
    let onStartCapture: () -> Void
    @ScaledMetric(relativeTo: .title3) private var guidanceLineHeight = 29

    private var showsResumeCard: Bool { resumeCandidate != nil && onResumeDraft != nil }

    var body: some View {
        GeometryReader { geometry in
            let reference = HomeTapeMeasure.referenceSize
            // 402pt 기준 기본 안내문 y=610, 이어하기 안내문 y=574·카드 y=652.
            // 두 상태의 줄자 크기를 같게 유지하고, 높이가 부족하면 스크롤합니다.
            let guidanceTop: CGFloat = showsResumeCard ? 574 : 610
            let scale = max(0, min(1, geometry.size.width / reference.width))
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HomeTapeMeasure(onStartCapture: onStartCapture)
                        .frame(width: reference.width * scale, height: reference.height * scale)
                    VStack(spacing: 0) {
                        Text("줄자 버튼을 눌러서")
                            .frame(minHeight: guidanceLineHeight)
                        Text("실측 시작하기").frame(minHeight: guidanceLineHeight)
                    }
                    .font(HomeTypography.guidance)
                    .tracking(-0.2)
                    .foregroundStyle(Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.guidance")
                    .padding(.horizontal, 20)
                    .padding(.top, (guidanceTop - reference.height) * scale)
                    if let candidate = resumeCandidate, let onResumeDraft {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            HomeResumeCard(step: candidate.draft.step, savedAt: candidate.draft.savedAt,
                                referenceDate: timeline.date, productName: candidate.garment.name,
                                onResume: { onResumeDraft(candidate.garment.id) }) {
                                if let photo = candidate.garment.thumbnail {
                                    StoredProductPhotoView(photo: photo, maximumPixelSize: 500)
                                } else {
                                    Color(white: 217.0 / 255)
                                }
                            }
                        }
                        .frame(maxWidth: 361)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color("HomeBackground").ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}
