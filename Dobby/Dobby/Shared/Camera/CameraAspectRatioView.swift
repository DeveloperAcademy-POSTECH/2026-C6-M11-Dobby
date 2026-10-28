// Created by mason on 10/22/26.
import SwiftUI

/// 선택값은 촬영 옵션 Model에 즉시 반영하고, 뒤로가기는 더보기 메뉴로 돌아간다.
struct CameraAspectRatioView: View {
    let state: CameraOptionsState
    let onSelectRatio: (String) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Text("비율").font(.caption)
                HStack {
                    Button("더보기로 돌아가기", systemImage: "chevron.left", action: onBack)
                        .labelStyle(.iconOnly).buttonStyle(.bordered).tint(.primary)
                        .buttonBorderShape(.circle).controlSize(.large)
                        .accessibilityIdentifier("camera.aspectRatioBack")
                    Spacer()
                }
            }
            Text(state.selectedAspectRatio)
                .font(.largeTitle).monospacedDigit()
                .accessibilityIdentifier("camera.aspectRatioValue")
            HStack(spacing: 32) {
                ForEach(state.aspectRatios, id: \.self) { ratio in
                    Button { onSelectRatio(ratio) } label: {
                        Text(ratio)
                            .font(.caption2).monospacedDigit()
                            .minimumScaleFactor(0.7).lineLimit(1)
                            .frame(width: 28, height: 28)
                            .background { RatioCorners().stroke(lineWidth: 1.5) }
                            .foregroundStyle(state.selectedAspectRatio == ratio ? .yellow : .white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("사진 비율 \(ratio)")
                    .accessibilityAddTraits(state.selectedAspectRatio == ratio ? .isSelected : [])
                    .accessibilityIdentifier("camera.aspectRatio.\(ratio)")
                }
            }
            .padding(.top, 4)
        }
        .padding(16).padding(.bottom, 32)
        .frame(maxWidth: .infinity)
        .glassEffect(.clear.tint(.black.opacity(0.15)), in: RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, 8).padding(.bottom, 24)
        .accessibilityIdentifier("camera.aspectRatioPanel")
        .accessibilityAction(.escape, onBack)
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

