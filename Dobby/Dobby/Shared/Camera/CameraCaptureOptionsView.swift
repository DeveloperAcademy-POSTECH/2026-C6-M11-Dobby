//
//  CameraCaptureOptionsView.swift
//  Dobby
//
//  Created by mason on 10/20/26.
//

import SwiftUI

/// 실측·상세 화면에서 재사용하는 촬영 옵션 UI. 값과 적용 동작은 호출자가 전달한다.
struct CameraCaptureOptionsView: View {
    var state = CameraOptionsState()
    var onExposureChange: (Double) -> Void = { _ in }
    var onAspectRatioChange: (String) -> Void = { _ in }
    let onClose: () -> Void
    @State private var showsExposure = false
    @State private var showsAspectRatio = false

    var body: some View {
        if showsExposure {
            CameraExposureView(state: state, onChangeExposure: onExposureChange) { showsExposure = false }
        } else if showsAspectRatio {
            CameraAspectRatioView(state: state, onSelectRatio: onAspectRatioChange) { showsAspectRatio = false }
        } else {
            menu
        }
    }

    private var menu: some View {
        HStack(spacing: 24) {
            option("노출", identifier: "camera.exposureOption", enabled: state.exposureRange != nil,
                   action: { showsExposure = true }) {
                Image(systemName: "plusminus").font(.title2)
            }
            option("비율", identifier: "camera.aspectRatioOption", enabled: !state.aspectRatios.isEmpty,
                   action: { showsAspectRatio = true }) {
                Text(state.selectedAspectRatio).font(.headline).monospacedDigit()
            }
        }
        .padding(.horizontal, 52)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 32))
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
                                    enabled: Bool = false, action: @escaping () -> Void = {},
                                    @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                    .frame(width: 48, height: 48)
                    .background(.quaternary, in: Circle())
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .secondary)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(title == "비율" ? state.selectedAspectRatio
                             : enabled ? "조절 가능" : "카메라 준비 후 사용 가능")
        .accessibilityIdentifier(identifier)
    }
}

// 실측 화면도 같은 방식으로 실제 적용값/지원 범위를 전달하고 콜백을 기존 제어기에 연결한다.
// 여기서 카메라 세션이나 측정 Model을 생성하지 않는다.
#Preview("공용 촬영 옵션 · 독립 상태") {
    @Previewable @State var state = CameraOptionsState(exposureRange: -2...2,
        appliedExposure: 0, aspectRatios: ["4:3", "16:9", "1:1"])
    CameraCaptureOptionsView(state: state,
        onExposureChange: { state.appliedExposure = $0 },
        onAspectRatioChange: { state.selectedAspectRatio = $0 }, onClose: {})
        .preferredColorScheme(.dark).background(Color.gray)
}
