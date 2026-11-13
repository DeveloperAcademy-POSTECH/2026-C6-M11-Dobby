import SwiftUI

struct ChakLoadingIndicator: View {
    let tint: Color

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(tint)
            .scaleEffect(1.5)
    }
}

#Preview("어두운 배경") {
    ChakLoadingIndicator(tint: Color(.brandNeutralWhite))
        .padding()
        .background(Color(.brandNeutral950))
}
