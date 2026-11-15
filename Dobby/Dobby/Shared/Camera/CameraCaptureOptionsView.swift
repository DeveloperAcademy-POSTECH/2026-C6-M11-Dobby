//
//  CameraCaptureOptionsView.swift
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

/// 실측·상세 화면에서 재사용하는 촬영 옵션 UI. 값과 적용 동작은 호출자가 전달한다.
struct CameraCaptureOptionsView: View {
    let state: CameraOptionsState
    let onExposureChange: (Double) -> Void
    let onAspectRatioChange: (String) -> Void
    let presentation: DetailCaptureOptionsPresentation
    private let selection: Binding<DetailCaptureOptionsDestination>?
    private let forceReduceMotion: Bool
    private let exposureSelectionFeedbackEnabled: Bool?
    private let panelLayout: CameraOptionsPanelLayout?
    let onClose: () -> Void
    @State private var localSelection: DetailCaptureOptionsDestination = .menu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: CameraOptionsState = CameraOptionsState(),
         onExposureChange: @escaping (Double) -> Void = { _ in },
         onAspectRatioChange: @escaping (String) -> Void = { _ in },
         presentation: DetailCaptureOptionsPresentation = .standard,
         selection: Binding<DetailCaptureOptionsDestination>? = nil,
         forceReduceMotion: Bool = false,
         exposureSelectionFeedbackEnabled: Bool? = nil,
         panelLayout: CameraOptionsPanelLayout? = nil,
         onClose: @escaping () -> Void) {
        self.state = state
        self.onExposureChange = onExposureChange
        self.onAspectRatioChange = onAspectRatioChange
        self.presentation = presentation
        self.selection = selection
        self.forceReduceMotion = forceReduceMotion
        self.exposureSelectionFeedbackEnabled = exposureSelectionFeedbackEnabled
        self.panelLayout = panelLayout
        self.onClose = onClose
    }

    private var destination: DetailCaptureOptionsDestination { selection?.wrappedValue ?? localSelection }
    private var effectiveReduceMotion: Bool { reduceMotion || forceReduceMotion }

    var body: some View {
        Group {
            if let panelLayout {
                CameraOptionsPanelSurface(layout: panelLayout) { panel }
            } else if presentation == .measurement {
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
            if destination == .exposure, state.exposureRange != nil {
                CameraExposureView(state: state, presentation: presentation,
                    forceReduceMotion: effectiveReduceMotion,
                    selectionFeedbackEnabled: exposureSelectionFeedbackEnabled,
                    embeddedInPanel: panelLayout != nil,
                    onChangeExposure: onExposureChange) { navigate(to: .menu) }
            } else if destination == .aspectRatio, !state.aspectRatios.isEmpty {
                CameraAspectRatioView(state: state, presentation: presentation,
                    embeddedInPanel: panelLayout != nil,
                    onSelectRatio: onAspectRatioChange) { navigate(to: .menu) }
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
        Group {
            if panelLayout != nil {
                menuContent
            } else {
                standaloneMenu
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.optionsMenu")
        .accessibilityAction(.escape, onClose)
    }

    private var menuContent: some View {
        HStack(spacing: presentation == .measurement ? 16 : 24) {
            option("노출", identifier: "camera.exposureOption", enabled: state.exposureRange != nil,
                   action: { navigate(to: .exposure) }) {
                Image(systemName: "plusminus").font(.title2)
            }
            option("비율", identifier: "camera.aspectRatioOption", enabled: !state.aspectRatios.isEmpty,
                   action: { navigate(to: .aspectRatio) }) {
                ZStack {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 28, weight: .regular))
                    Text(state.selectedAspectRatio)
                        .font(.system(size: 11, weight: .regular)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 24)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            }
        }
    }

    private var standaloneMenu: some View {
        menuContent
        .padding(.horizontal, presentation == .measurement ? 12 : 52)
        .padding(.top, presentation == .measurement ? 12 : 24)
        .padding(.bottom, presentation == .measurement ? 12 : 16)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 32))
        .padding(.horizontal, presentation == .measurement ? 8 : 16)
        .padding(.bottom, presentation == .measurement ? 16 : 24)
        .frame(minHeight: 148, alignment: .bottom)
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

#Preview("공용 촬영 옵션 · 독립 상태") {
    @Previewable @State var state = CameraOptionsState(exposureRange: -2...2,
        appliedExposure: 0, aspectRatios: ["4:3", "16:9", "1:1"])
    CameraCaptureOptionsView(state: state,
        onExposureChange: { state.appliedExposure = $0 },
        onAspectRatioChange: { state.selectedAspectRatio = $0 }, onClose: {})
        .preferredColorScheme(.dark).background(Color.gray)
}
