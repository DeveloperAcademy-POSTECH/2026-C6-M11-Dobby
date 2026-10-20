//
//  DetailCaptureOptionsView.swift
//  Dobby
//
//  Created by mason on 10/20/26.
//

import SwiftUI

/// 5단계는 메뉴 표시만 제공한다. 노출·비율 조작과 카메라 적용은 후속 단계다.
struct DetailCaptureOptionsView: View {
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            option("노출", identifier: "camera.exposureOption") {
                Image(systemName: "plusminus").font(.title2)
            }
            option("비율", identifier: "camera.aspectRatioOption") {
                // UI 기본 표시이며 현재 저장 사진의 비율을 조회한 값은 아니다.
                Text("4:3").font(.headline).monospacedDigit()
            }
        }
        .padding(.horizontal, 52)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel("촬영 옵션 닫기")
            .accessibilityIdentifier("camera.closeOptions")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(minHeight: 148, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.optionsMenu")
        .accessibilityAction(.escape, onClose)
    }

    private func option<Icon: View>(_ title: String, identifier: String,
                                    @ViewBuilder icon: () -> Icon) -> some View {
        Button { /* 노출·비율 조절은 후속 단계에서 연결한다. */ } label: {
            VStack(spacing: 8) {
                icon()
                    .frame(width: 48, height: 48)
                    .background(.quaternary, in: Circle())
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(true)
        .accessibilityLabel(title)
        .accessibilityValue(title == "비율" ? "4:3, 조절 준비 중" : "조절 준비 중")
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    DetailCaptureOptionsView(onClose: {})
        .preferredColorScheme(.dark)
        .background(Color.gray)
}
