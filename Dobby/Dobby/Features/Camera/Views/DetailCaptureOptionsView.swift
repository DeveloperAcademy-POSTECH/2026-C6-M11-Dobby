//
//  DetailCaptureOptionsView.swift
//  Dobby
//
//  Created by mason on 10/20/26.
//

import SwiftUI

nonisolated enum DetailCaptureOptionsDestination: String, Sendable, CaseIterable {
    case menu, exposure, aspectRatio

    /// A backdrop or Escape first returns from a child panel to its menu.
    /// At the menu, its owner can dismiss the complete options presentation.
    var parent: Self? { self == .menu ? nil : .menu }
}

/// Detail capture keeps its existing presentation unless a caller opts into
/// the measurement camera's compact animated bottom panel.
nonisolated enum DetailCaptureOptionsPresentation: Sendable {
    case standard, measurement

    func animation(reduceMotion: Bool) -> Animation? {
        guard self == .measurement else { return nil }
        return reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.90)
    }

    func transition(reduceMotion: Bool) -> AnyTransition {
        guard self == .measurement else { return .identity }
        return reduceMotion ? .opacity
            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }
}

/// 노출과 비율 패널은 동일한 촬영 옵션 Model을 공유한다.
struct DetailCaptureOptionsView: View {
    let options: DetailCameraOptions?
    let presentation: DetailCaptureOptionsPresentation
    private let selection: Binding<DetailCaptureOptionsDestination>?
    private let forceReduceMotion: Bool
    let onClose: () -> Void
    @State private var localSelection: DetailCaptureOptionsDestination = .menu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(options: DetailCameraOptions? = nil,
         presentation: DetailCaptureOptionsPresentation = .standard,
         selection: Binding<DetailCaptureOptionsDestination>? = nil,
         forceReduceMotion: Bool = false,
         onClose: @escaping () -> Void) {
        self.options = options
        self.presentation = presentation
        self.selection = selection
        self.forceReduceMotion = forceReduceMotion
        self.onClose = onClose
    }

    private var destination: DetailCaptureOptionsDestination { selection?.wrappedValue ?? localSelection }
    private var effectiveReduceMotion: Bool { reduceMotion || forceReduceMotion }

    var body: some View {
        Group {
            if presentation == .measurement {
                ViewThatFits(in: .vertical) {
                    panel.fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) { panel }
                        .scrollIndicators(.hidden)
                }
            } else {
                panel
            }
        }
        // The owning camera animates opening/closing this complete container;
        // this view animates only navigation between its own child panels.
        .animation(presentation.animation(reduceMotion: effectiveReduceMotion), value: destination)
    }

    private var panel: some View {
        Group {
            if destination == .exposure, let options {
                DetailExposureView(options: options, presentation: presentation,
                    forceReduceMotion: effectiveReduceMotion) { navigate(to: .menu) }
            } else if destination == .aspectRatio, let options {
                DetailAspectRatioView(options: options, presentation: presentation) { navigate(to: .menu) }
            } else {
                menu
            }
        }
        .id(destination)
        .transition(presentation.transition(reduceMotion: effectiveReduceMotion))
    }

    private func navigate(to destination: DetailCaptureOptionsDestination) {
        if let selection { selection.wrappedValue = destination }
        else { localSelection = destination }
    }

    private var menu: some View {
        HStack(spacing: presentation == .measurement ? 16 : 24) {
            option("노출", identifier: "camera.exposureOption", enabled: options?.capabilities.exposure != nil,
                   action: { navigate(to: .exposure) }) {
                Image(systemName: "plusminus").font(.title2)
            }
            option("비율", identifier: "camera.aspectRatioOption", enabled: options != nil,
                   action: { navigate(to: .aspectRatio) }) {
                Text(options?.photoAspectRatio.rawValue ?? "4:3").font(.headline).monospacedDigit()
            }
        }
        .padding(.horizontal, presentation == .measurement ? 12 : 52)
        // Reserve the close button's complete row in narrow landscape panels.
        .padding(.top, presentation == .measurement ? 52 : 24)
        .padding(.bottom, presentation == .measurement ? 12 : 16)
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
        .padding(.horizontal, presentation == .measurement ? 8 : 16)
        .padding(.bottom, presentation == .measurement ? 16 : 24)
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
