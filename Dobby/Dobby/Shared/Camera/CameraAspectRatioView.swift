// Created by mason on 10/22/26.
import SwiftUI

/// 선택값은 촬영 옵션 Model에 즉시 반영하고, 뒤로가기는 더보기 메뉴로 돌아간다.
struct CameraAspectRatioView: View {
    let state: CameraOptionsState
    let onSelectRatio: (String) -> Void
    let presentation: DetailCaptureOptionsPresentation
    private let embeddedInPanel: Bool
    let onBack: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(state: CameraOptionsState, presentation: DetailCaptureOptionsPresentation = .standard,
         embeddedInPanel: Bool = false,
         onSelectRatio: @escaping (String) -> Void, onBack: @escaping () -> Void) {
        self.state = state
        self.onSelectRatio = onSelectRatio
        self.presentation = presentation
        self.embeddedInPanel = embeddedInPanel
        self.onBack = onBack
    }

    private var ratioSide: CGFloat {
        (embeddedInPanel || presentation == .measurement) && dynamicTypeSize.isAccessibilitySize ? 64 : 28
    }
    private var ratioTouchSide: CGFloat { max(44, ratioSide) }

    var body: some View {
        Group {
            if embeddedInPanel { controls }
            else {
                controls
                    .padding(presentation == .measurement ? 12 : 16)
                    .padding(.bottom, presentation == .measurement ? 8 : 32)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 40))
                    .padding(.horizontal, 8).padding(.bottom, presentation == .measurement ? 16 : 24)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.aspectRatioPanel")
        .accessibilityAction(.escape, onBack)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            header
            Text(state.selectedAspectRatio)
                .font(embeddedInPanel ? .system(.title, design: .rounded).weight(.light)
                    : presentation == .measurement ? .title2 : .largeTitle).monospacedDigit()
                .accessibilityIdentifier("camera.aspectRatioValue")
            Group {
                if embeddedInPanel || presentation == .measurement {
                    ViewThatFits(in: .horizontal) {
                        ratioRow(spacing: 20)
                        ratioRow(spacing: 0)
                        VStack(spacing: 12) { ratioButtons }
                    }
                } else {
                    ratioRow(spacing: 32)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        Group {
            if (embeddedInPanel || presentation == .measurement) && dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    HStack { backButton; Spacer() }
                    Text("비율").font(.caption)
                }
            } else {
                ZStack {
                    Text("비율").font(.caption)
                    HStack { backButton; Spacer() }
                }
            }
        }
    }

    private var backButton: some View {
        Button("더보기로 돌아가기", systemImage: "chevron.left", action: onBack)
            .labelStyle(.iconOnly).buttonStyle(.bordered).tint(.primary)
            .buttonBorderShape(.circle).controlSize(.large)
            .accessibilityIdentifier("camera.aspectRatioBack")
    }

    private func ratioRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) { ratioButtons }
            .fixedSize(horizontal: true, vertical: false)
    }

    private var ratioButtons: some View {
        ForEach(state.aspectRatios, id: \.self) { ratio in
            Button { onSelectRatio(ratio) } label: {
                Text(ratio)
                    .font(.caption2).monospacedDigit()
                    .minimumScaleFactor(0.7).lineLimit(1)
                    .frame(width: ratioSide, height: ratioSide)
                    .background { RatioCorners().stroke(lineWidth: 1.5) }
                    .foregroundStyle(state.selectedAspectRatio == ratio ? .yellow : .white)
                    .frame(width: ratioTouchSide, height: ratioTouchSide).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("사진 비율 \(ratio)")
            .accessibilityAddTraits(state.selectedAspectRatio == ratio ? .isSelected : [])
            .accessibilityIdentifier("camera.aspectRatio.\(ratio)")
        }
    }
}

private struct RatioCorners: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for x in [rect.minX, rect.maxX] {
                for y in [rect.minY, rect.maxY] {
                    let dx: CGFloat = x == rect.minX ? 6 : -6
                    let dy: CGFloat = y == rect.minY ? 6 : -6
                    path.move(to: CGPoint(x: x, y: y + dy))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx, y: y))
                }
            }
        }
    }
}
