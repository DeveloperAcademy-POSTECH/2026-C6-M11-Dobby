import SwiftUI

struct ChakLoadingIndicator: View {
    let tint: Color

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .tint(tint)
            .scaleEffect(1.2)
    }
}
