import SwiftUI

struct ExportHeaderView: View {
    let onClose: () -> Void

    var body: some View {
        Text("내보내기")
            .font(.headline.weight(.regular))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .padding(.horizontal, 76)
            .overlay(alignment: .leading) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle()
                                .fill(.linearGradient(colors: [Color(white: 0.94), .white], startPoint: .top, endPoint: .bottom))
                                .overlay {
                                    Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
                                }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("닫기")
                .accessibilityIdentifier("export.close")
                .padding(.leading, 16)
            }
            .padding(.vertical, 8)
            .background(.white)
    }
}

#Preview("내보내기 헤더", traits: .sizeThatFitsLayout) {
    ExportHeaderView(onClose: {})
}
