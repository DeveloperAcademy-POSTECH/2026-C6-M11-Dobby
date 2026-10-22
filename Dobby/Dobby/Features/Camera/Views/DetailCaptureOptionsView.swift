//
//  DetailCaptureOptionsView.swift
//  Dobby
//
//  Created by mason on 10/20/26.
//

import SwiftUI

/// 노출과 비율 패널은 동일한 촬영 옵션 Model을 공유한다.
struct DetailCaptureOptionsView: View {
    var options: DetailCameraOptions? = nil
    let onClose: () -> Void
    @State private var showsExposure = false
    @State private var showsAspectRatio = false

    var body: some View {
        if showsExposure, let options {
            DetailExposureView(options: options) { showsExposure = false }
        } else if showsAspectRatio, let options {
            DetailAspectRatioView(options: options) { showsAspectRatio = false }
        } else {
            menu
        }
    }

    private var menu: some View {
        HStack(spacing: 24) {
            option("노출", identifier: "camera.exposureOption", enabled: options?.capabilities.exposure != nil,
                   action: { showsExposure = true }) {
                Image(systemName: "plusminus").font(.title2)
            }
            option("비율", identifier: "camera.aspectRatioOption", enabled: options != nil,
                   action: { showsAspectRatio = true }) {
                Text(options?.photoAspectRatio.rawValue ?? "4:3").font(.headline).monospacedDigit()
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
        .accessibilityValue(title == "비율" ? options?.photoAspectRatio.rawValue ?? "사용 불가"
                             : enabled ? "조절 가능" : "카메라 준비 후 사용 가능")
        .accessibilityIdentifier(identifier)
    }
}

#Preview {
    DetailCaptureOptionsView(onClose: {})
        .preferredColorScheme(.dark)
        .background(Color.gray)
}
