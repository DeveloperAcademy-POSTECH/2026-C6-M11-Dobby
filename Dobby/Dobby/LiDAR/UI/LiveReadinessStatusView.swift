import SwiftUI

extension LiveCaptureReadiness {
    nonisolated static var waiting: Self { .status(.analyzing) }

    nonisolated static func status(_ state: LiveReadinessState, timestamp: TimeInterval = 0) -> Self {
        .init(state: state, timestamp: timestamp, bounds: nil, depthCoverage: nil,
              highConfidenceCoverage: nil, boundaryCoverage: nil, medianDepthMeters: nil)
    }
}

extension LiveReadinessState {
    var title: String {
        switch self {
        case .searching: "옷 후보를 찾는 중"
        case .analyzing: "실시간 상태 확인 중"
        case .unsupportedGarment: "이 옷은 자동 실측을 지원하지 않아요"
        case .multipleObjects: "여러 대상이 보여요"
        case .clipped: "옷 끝부분을 확인해 주세요"
        case .tooSmall: "옷이 너무 작게 보여요"
        case .noDepth: "LiDAR 깊이를 기다리는 중"
        case .lowDepth: "대상의 깊이가 부족해요"
        case .unstable: "카메라를 잠시 멈춰 주세요"
        case .steadying: "깊이 확보 · 안정화 중"
        case .ready: "깊이 확보 · 촬영 가능"
        case .analysisFailed: "대상을 확인하기 어려워요"
        }
    }

    var hint: String {
        switch self {
        case .searching: "옷을 펼치고 배경과 구분되도록 비춰 주세요."
        case .analyzing: "최신 영상에서 대상 영역과 깊이를 확인합니다."
        case .unsupportedGarment: "현재 긴팔·반팔 상의와 바지·반바지를 지원해요"
        case .multipleObjects: "주변 물건을 치우고 옷 한 벌만 펼쳐 주세요."
        case .clipped: "소매와 밑단까지 보이도록 조금 멀리 이동하세요."
        case .tooSmall: "옷 전체를 유지하며 조금 가까이 이동하세요."
        case .noDepth: "LiDAR 센서를 가리지 말고 잠시 기다려 주세요."
        case .lowDepth: "거리나 각도를 조금 바꿔 주세요. 가장자리 깊이도 필요합니다."
        case .unstable: "기기를 안정적으로 잡고 옷을 움직이지 말아 주세요."
        case .steadying: "같은 대상을 연속으로 확인하고 있습니다. 잠시 유지하세요."
        case .ready: "테두리 안의 대상이 옷인지 확인한 뒤 촬영하세요."
        case .analysisFailed: "옷과 배경이 구분되는지, 조명이 충분한지 확인하세요."
        }
    }

    var tint: Color {
        switch self {
        case .ready: .mint
        case .searching, .analyzing: .white
        case .unsupportedGarment: .orange
        default: .orange
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .searching, .analyzing: "viewfinder"
        case .unsupportedGarment: "minus.circle.fill"
        case .steadying: "hourglass"
        case .unstable: "hand.raised.fill"
        default: "exclamationmark.circle.fill"
        }
    }
}

/// Garment recognition and usable depth are separate from centimetre accuracy.
struct LiveReadinessStatusView: View {
    let readiness: LiveCaptureReadiness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(readiness.state.title, systemImage: readiness.state.symbol)
                .font(.headline).foregroundStyle(readiness.state.tint)
                .accessibilityIdentifier("liveReadinessTitle")
            Text(readiness.state.hint).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            if let coverage = readiness.depthCoverage {
                HStack(spacing: 12) {
                    Text("영역 깊이 \(Int((coverage * 100).rounded()))%")
                    if let edge = readiness.boundaryCoverage {
                        Text("가장자리 \(Int((edge * 100).rounded()))%")
                    }
                }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
            }
            Text(readiness.garmentRecognized
                 ? "\(readiness.garmentKind?.title ?? "옷") 인식 확인 · 영역과 깊이 상태 안내"
                 : "옷 인식과 깊이 상태를 확인하고 있습니다")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .foregroundStyle(.white)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .contain)
    }
}

/// A deterministic rehearsal of the same evaluator and status card used by the
/// camera. This remains available on simulators and devices without LiDAR.
struct LiveReadinessDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scenario: ReadinessDemoScenario = .good
    @State private var readiness = LiveCaptureReadiness.waiting

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("합성 상태 미리보기").font(.title2.bold())
                    Text("실제 카메라나 옷 인식 결과가 아닙니다. 촬영 중 표시될 안내와 상태 전환을 확인할 수 있습니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 24).fill(Color(red: 0.14, green: 0.20, blue: 0.21))
                        Image(systemName: "tshirt.fill").font(.system(size: 135)).foregroundStyle(.white.opacity(0.8))
                        RoundedRectangle(cornerRadius: 16).stroke(readiness.state.tint, style: StrokeStyle(lineWidth: 3, dash: readiness.state == .ready ? [] : [8, 5]))
                            .padding(28)
                    }.frame(height: 240).accessibilityHidden(true)
                    LiveReadinessStatusView(readiness: readiness)
                    VStack(spacing: 8) {
                        ForEach(ReadinessDemoScenario.allCases) { value in
                            Button { scenario = value } label: {
                                HStack {
                                    Text(value.title)
                                    Spacer()
                                    if scenario == value { Image(systemName: "checkmark") }
                                }.padding(8).frame(maxWidth: .infinity)
                            }.buttonStyle(.bordered).accessibilityIdentifier("readinessDemo_\(value.rawValue)")
                        }
                    }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }.background(Color(.systemGroupedBackground))
                .navigationTitle("실시간 안내 테스트").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .task(id: scenario) {
                    var evaluator = LiveReadinessEvaluator()
                    let first = evaluator.evaluate(scenario.evidence(timestamp: 1))
                    // Synthetic timestamps let this preview exercise the temporal
                    // gate deterministically, without a timer tied to view lifetime.
                    readiness = scenario == .settling ? first : evaluator.evaluate(scenario.evidence(timestamp: 1.7))
                }
        }.tint(.teal)
    }
}

private enum ReadinessDemoScenario: String, CaseIterable, Identifiable {
    case good, settling, missing, weak, multiple, moving, clipped
    var id: String { rawValue }
    var title: String {
        switch self {
        case .good: "정상 깊이 · 촬영 가능"
        case .settling: "깊이 확보 후 안정화 중"
        case .missing: "깊이 데이터 없음"
        case .weak: "깊이 신뢰도 부족"
        case .multiple: "대상이 여러 개"
        case .moving: "카메라 움직임"
        case .clipped: "대상이 촬영 영역 밖으로 잘림"
        }
    }
    func evidence(timestamp: TimeInterval) -> LiveCaptureEvidence {
        let size = PixelSize(width: 80, height: 60)
        var mask = [UInt8](repeating: 0, count: 80 * 60)
        let xStart = self == .clipped ? 0 : 16
        for y in 12..<48 {
            for x in xStart..<64 { mask[y * 80 + x] = 1 }
        }
        return .init(timestamp: timestamp, candidateCount: self == .multiple ? 2 : 1,
                     bounds: .init(x: Double(xStart) / 80, y: 0.2, width: Double(64 - xStart) / 80, height: 0.6),
                     mask: .init(size: size, values: mask), imageSize: .init(width: 640, height: 480),
                     depth: self == .missing ? nil : .init(size: size, values: .init(repeating: 1, count: 80 * 60),
                         confidence: .init(repeating: self == .weak ? 1 : 2, count: 80 * 60)),
                     trackingStable: self != .moving,
                     recognitionModelVersion: "synthetic-readiness-preview")
    }
}
