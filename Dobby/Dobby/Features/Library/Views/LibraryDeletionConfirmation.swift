import SwiftUI
import UIKit

/// Uses native alert actions in a fixed order without SwiftUI adding a cancel action.
struct LibraryDeletionConfirmation: UIViewControllerRepresentable {
    @Binding var productID: UUID?
    let onDelete: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.onAppear = { [weak coordinator = context.coordinator, weak presenter] in
            guard let presenter else { return }
            coordinator?.updatePresentation(from: presenter)
        }
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.updatePresentation(from: presenter)
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: Coordinator) {
        presenter.onAppear = nil
        coordinator.dismiss(animated: false)
    }

    final class Presenter: UIViewController {
        var onAppear: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onAppear?()
        }
    }

    final class Coordinator: NSObject {
        var configuration: LibraryDeletionConfirmation
        private weak var alert: UIAlertController?

        init(configuration: LibraryDeletionConfirmation) {
            self.configuration = configuration
        }

        func updatePresentation(from presenter: Presenter) {
            guard let productID = configuration.productID else {
                dismiss(animated: true)
                return
            }
            guard alert == nil, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil else { return }

            let alert = UIAlertController(title: "이 작업을 삭제하겠습니까?",
                message: "삭제된 작업은 복구할 수 없어요", preferredStyle: .alert)
            alert.overrideUserInterfaceStyle = .light
            alert.view.tintColor = .black
            alert.addAction(UIAlertAction(title: "삭제하기", style: .destructive) { [weak self] _ in
                guard let self else { return }
                let onDelete = configuration.onDelete
                self.alert = nil
                configuration.productID = nil
                onDelete(productID)
            })
            // Default style preserves the trailing position and black text.
            alert.addAction(UIAlertAction(title: "취소", style: .default) { [weak self] _ in
                self?.alert = nil
                self?.configuration.productID = nil
            })
            self.alert = alert
            presenter.present(alert, animated: true)
        }

        func dismiss(animated: Bool) {
            alert?.dismiss(animated: animated)
            alert = nil
        }

    }
}
