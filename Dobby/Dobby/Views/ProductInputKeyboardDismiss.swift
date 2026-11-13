import SwiftUI

/// Keep editable fields and controls out of the background's keyboard-dismiss hit area.
struct ProductInputInteractionBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func productInputInteractionArea() -> some View {
        anchorPreference(key: ProductInputInteractionBounds.self, value: .bounds) { [$0] }
    }
}

struct ProductInputKeyboardDismissBackground: View {
    let bounds: [Anchor<CGRect>]
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ProductInformationStyle.background
                .contentShape(BackgroundHitArea(exclusions: bounds.map { proxy[$0] }), eoFill: true)
                .onTapGesture(perform: onDismiss)
        }
    }

    private struct BackgroundHitArea: Shape {
        let exclusions: [CGRect]
        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            for exclusion in exclusions {
                let clipped = exclusion.intersection(rect)
                if !clipped.isNull, !clipped.isEmpty { path.addRect(clipped) }
            }
            return path
        }
    }
}
