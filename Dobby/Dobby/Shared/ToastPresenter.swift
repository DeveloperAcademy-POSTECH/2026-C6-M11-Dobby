import Observation
import SwiftUI

@MainActor
@Observable
final class ToastPresenter {
    struct Item: Identifiable {
        let id = UUID()
        let message: String
    }

    private(set) var current: Item?

    func show(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            current = Item(message: message)
        }
    }

    fileprivate func dismiss(id: UUID) {
        guard current?.id == id else { return }
        current = nil
    }
}

private struct ToastModifier: ViewModifier {
    @State private var presenter = ToastPresenter()
    let bottomPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .environment(presenter)
            .overlay(alignment: .bottom) {
                ToastOverlay(presenter: presenter)
                    .padding(.bottom, bottomPadding)
            }
    }
}

private struct ToastOverlay: View {
    let presenter: ToastPresenter

    var body: some View {
        if let item = presenter.current {
            ToastMessageView(message: item.message)
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: item.id) {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }

                    withAnimation(.easeOut(duration: 0.2)) {
                        presenter.dismiss(id: item.id)
                    }
                }
        }
    }
}

extension View {
    func toast(bottomPadding: CGFloat = 84) -> some View {
        modifier(ToastModifier(bottomPadding: bottomPadding))
    }
}
