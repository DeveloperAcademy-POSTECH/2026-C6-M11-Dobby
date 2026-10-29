//
//  ProductPhotoAIOptionRow.swift
//  Dobby
//
//  Created by mason on 10/29/26.
//

import SwiftUI

/// AI 입력 옵션의 표시만 담당합니다. 기본값과 실제 처리 연결은 부모가 소유합니다.
struct ProductPhotoAIOptionRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("AI로 제품 정보 입력하기")
                .font(.headline)
                .tracking(-0.43)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .tint(Color("BrandPrimary100"))
        .accessibilityIdentifier("camera.aiInformationToggle")
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(Color(.systemBackground))
    }
}
