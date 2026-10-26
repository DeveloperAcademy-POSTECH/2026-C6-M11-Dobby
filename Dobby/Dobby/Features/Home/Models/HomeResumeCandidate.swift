//
//  HomeResumeCandidate.swift
//  Dobby
//
//  Created by mason on 10/27/26.
//

import Foundation

/// 기존 저장 초안을 홈 카드에 전달하는 읽기 전용 값. 별도 저장소를 만들지 않는다.
@MainActor
struct HomeResumeCandidate {
    let garment: Garment
    let draft: ProductCreationDraft

    static func latest(in garments: [Garment]) -> HomeResumeCandidate? {
        garments.compactMap { garment -> HomeResumeCandidate? in
            guard garment.informationCompletedAt == nil,
                  let draft = garment.creationDraft,
                  garment.sourceMeasurementID == draft.measurementRecordID,
                  draft.step == .measurementResult || draft.photoState != nil else { return nil }
            // 원본 파일과 실측 기록 검증은 기존 복원 흐름에서 수행하고 오류를 안내한다.
            return HomeResumeCandidate(garment: garment, draft: draft)
        }.max { lhs, rhs in
            if lhs.draft.savedAt != rhs.draft.savedAt {
                return lhs.draft.savedAt < rhs.draft.savedAt
            }
            // 같은 저장 시각에도 SwiftData 조회 순서에 따라 카드가 바뀌지 않도록 한다.
            return lhs.garment.id.uuidString < rhs.garment.id.uuidString
        }
    }
}
