import SwiftUI

struct InstagramUploadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                Text("업로드 중...")
                    .font(.title3.bold())
                RulerLoadingIndicator()
                    .frame(height: 96)
                Text("인스타그램에 자동으로 업로드하고 있어요!\n조금만 기다려 주세요")
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: 360)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 21)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("인스타그램에 업로드 중입니다. 조금만 기다려 주세요.")
    }
}

private struct RulerLoadingIndicator: View {
    @State private var isMoving = false

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<42, id: \.self) { index in
                    VStack(spacing: 4) {
                        if index.isMultiple(of: 2) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                        }
                        Rectangle()
                            .frame(width: 1, height: index.isMultiple(of: 2) ? 24 : 13)
                    }
                    .frame(width: 28, alignment: .bottom)
                }
            }
            .foregroundStyle(Color(.brandNeutral800))
            .offset(x: isMoving ? -210 : -14)
            .onAppear {
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                    isMoving = true
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipped()
        }
    }
}
