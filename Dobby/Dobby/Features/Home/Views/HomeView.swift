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
    @ScaledMetric(relativeTo: .body) private var draftGuidanceLineHeight = 24

    private var showsResumeCard: Bool { resumeCandidate != nil && onResumeDraft != nil }

    var body: some View {
        GeometryReader { geometry in
            let reference = HomeTapeMeasure.referenceSize
            // 기본 안내문 y=610, draft 안내문 y=589·카드 y=645. 작은 화면은 스크롤을 허용합니다.
            let lineHeight = showsResumeCard ? draftGuidanceLineHeight : guidanceLineHeight
            let guidanceTop: CGFloat = showsResumeCard ? 589 : 610
            let cardSpace: CGFloat = showsResumeCard ? 133 : 0
            let availableHeight = max(0, geometry.size.height - lineHeight * 2 - 24 - cardSpace)
            let scale = max(0.35, min(1, geometry.size.width / reference.width, availableHeight / guidanceTop))
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HomeTapeMeasure(showsMarkings: !showsResumeCard, onStartCapture: onStartCapture)
                        .frame(width: reference.width * scale, height: reference.height * scale)
                    VStack(spacing: 0) {
                        Text(showsResumeCard ? "줄자 버튼을 누르고" : "줄자 버튼을 눌러서")
                            .frame(minHeight: lineHeight)
                        Text("실측 시작하기").frame(minHeight: lineHeight)
                    }
                    .font(showsResumeCard ? HomeTypography.draftGuidance : HomeTypography.guidance)
                    .tracking(showsResumeCard ? -0.43 : -0.2)
                    .foregroundStyle(showsResumeCard ? Color(white: 144 / 255)
                        : Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home.guidance")
                    .padding(.horizontal, 20)
                    .padding(.top, (guidanceTop - reference.height) * scale)
                    if let candidate = resumeCandidate, let onResumeDraft {
                        TimelineView(.periodic(from: .now, by: 60)) { timeline in
                            HomeResumeCard(step: candidate.draft.step, savedAt: candidate.draft.savedAt,
                                referenceDate: timeline.date,
                                onResume: { onResumeDraft(candidate.garment.id) }) {
                                if let photo = candidate.garment.thumbnail {
                                    StoredProductPhotoView(photo: photo, maximumPixelSize: 500)
                                } else {
                                    Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
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
