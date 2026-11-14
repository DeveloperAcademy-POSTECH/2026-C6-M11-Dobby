import SwiftUI

struct ExportToolbarTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.custom("Pretendard-SemiBold", size: 17, relativeTo: .headline))
            .accessibilityAddTraits(.isHeader)
    }
}
