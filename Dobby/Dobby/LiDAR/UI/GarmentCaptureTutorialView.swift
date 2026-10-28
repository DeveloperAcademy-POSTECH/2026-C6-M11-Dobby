import SwiftUI

/// An introduction over the running camera. The parent owns navigation and
/// persists the opt-out binding; this overlay never replaces the live preview.
struct GarmentCaptureTutorialView: View {
    @Binding var skipsTutorial: Bool
    var onContinue: () -> Void

    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 33
    @ScaledMetric(relativeTo: .callout) private var detailLineHeight: CGFloat = 22.4
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.opacity(0.60)
                    .accessibilityHidden(true)

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        instructions

                        shirtGuide(width: min(232, max(0, geometry.size.width - 38)))
                            // The exported tee includes transparent margins.
                            // Keep its Figma image slot just above the copy's
                            // lower edge rather than cropping those margins.
                            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 12 : -5.8)

                        actions
                            .padding(.top, 17.725)
                    }
                    .padding(.horizontal, 19)
                    .padding(.top, topInset(in: geometry.size))
                    .padding(.bottom, max(24, geometry.safeAreaInsets.bottom + 16))
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("garmentCaptureTutorial")
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("먼저 옷을 바닥에 놓고,")
                    .frame(minHeight: titleLineHeight, alignment: .leading)
                Text("주름이 없게 펴서 배치해주세요")
                    .frame(minHeight: titleLineHeight, alignment: .leading)
            }
            .font(.title2.weight(.bold))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                Text("아래 표시된 지점들이 접히지 않게 촬영하면")
                    .frame(minHeight: detailLineHeight, alignment: .leading)
                Text("쉽고 정확하게 실측을 끝낼 수 있어요")
                    .frame(minHeight: detailLineHeight, alignment: .leading)
            }
            .font(.callout.weight(.semibold))
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shirtGuide(width: CGFloat) -> some View {
        // Six Figma markers belong to the exported image's coordinate system.
        // They scale together with the image, independently of Dynamic Type.
        GeometryReader { geometry in
            let scale = geometry.size.width / 232
            ZStack(alignment: .topLeading) {
                Image("GarmentCaptureTutorialShirt")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 217.331 * scale, height: 289.775 * scale)
                    .position(x: 114.13 * scale, y: 144.8875 * scale)

                ForEach(Array(Self.measurementPoints.enumerated()), id: \.offset) { _, point in
                    Image("GarmentCaptureTutorialMeasurementPoint")
                        .resizable()
                        .frame(width: 21.8698 * scale, height: 21.8698 * scale)
                        .position(x: point.x * scale, y: point.y * scale)
                }
            }
        }
        .frame(width: width, height: width * 289.775 / 232)
        .offset(x: width * 2 / 232)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("반팔 옷을 펼친 예시. 양쪽 소매 끝, 겨드랑이, 밑단의 여섯 지점이 접히지 않게 펼쳐 주세요")
        .accessibilityIdentifier("garmentCaptureTutorialShirt")
    }

    private var actions: some View {
        VStack(spacing: 5.5) {
            Toggle("다음부터 이 튜토리얼 건너뛰기", isOn: $skipsTutorial)
                .toggleStyle(CaptureTutorialCheckboxStyle())
                .accessibilityIdentifier("skipGarmentCaptureTutorial")

            Button(action: onContinue) {
                Text("배치했어요")
                    .font(.callout.weight(.semibold).italic())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(GarmentCaptureStyle.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("continueGarmentCaptureTutorial")
        }
        .frame(maxWidth: dynamicTypeSize > .large ? 360 : 190)
        .offset(x: 0.5)
    }

    private func topInset(in size: CGSize) -> CGFloat {
        // The parent supplies full-screen bounds; its native toolbar overlays
        // the space above this copy.
        // Keep the reference 132pt top on a 402×874pt phone; compact windows
        // remain scrollable without moving the copy under the navigation bar.
        min(132, max(116, size.height * 132 / 874))
    }

    private static let measurementPoints: [CGPoint] = [
        .init(x: 54.6749, y: 129.8549),
        .init(x: 10.9349, y: 94.3149),
        .init(x: 54.6749, y: 233.7349),
        .init(x: 177.6949, y: 129.8549),
        .init(x: 220.0649, y: 94.3149),
        .init(x: 177.6949, y: 233.7349)
    ]
}

private struct CaptureTutorialCheckboxStyle: ToggleStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.54))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color(white: 117 / 255), lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            CaptureTutorialCheckmark()
                                .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                                .padding(4)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                configuration.label
                    .font(.custom("Pretendard-Regular", size: 14, relativeTo: .subheadline))
                    .tracking(-0.14)
                    .foregroundStyle(.white.opacity(0.80))
                    .fixedSize(horizontal: dynamicTypeSize <= .large, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "켬" : "끔")
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

private struct CaptureTutorialCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: .init(x: rect.minX, y: rect.midY))
            path.addLine(to: .init(x: rect.minX + rect.width * 0.37, y: rect.maxY))
            path.addLine(to: .init(x: rect.maxX, y: rect.minY))
        }
    }
}
