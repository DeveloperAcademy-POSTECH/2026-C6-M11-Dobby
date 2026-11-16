import SwiftUI
import UIKit

/// Presents the design-system confirmation above the navigation and tab bars.
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
        private weak var confirmation: UIViewController?

        init(configuration: LibraryDeletionConfirmation) {
            self.configuration = configuration
        }

        func updatePresentation(from presenter: Presenter) {
            guard let productID = configuration.productID else {
                dismiss(animated: true)
                return
            }
            guard confirmation == nil, presenter.viewIfLoaded?.window != nil,
                  presenter.presentedViewController == nil else { return }

            let content = LibraryDeletionConfirmationView(
                onDelete: { [weak self] in
                    guard let self else { return }
                    let onDelete = configuration.onDelete
                    configuration.productID = nil
                    dismiss(animated: true)
                    onDelete(productID)
                },
                onCancel: { [weak self] in
                    self?.configuration.productID = nil
                    self?.dismiss(animated: true)
                }
            )
            let confirmation = UIHostingController(rootView: content)
            confirmation.view.backgroundColor = .clear
            confirmation.view.accessibilityViewIsModal = true
            confirmation.modalPresentationStyle = .overFullScreen
            confirmation.modalTransitionStyle = .crossDissolve
            self.confirmation = confirmation
            presenter.present(confirmation, animated: true)
        }

        func dismiss(animated: Bool) {
            confirmation?.dismiss(animated: animated)
            confirmation = nil
        }
    }
}

struct LibraryDeletionConfirmationView: View {
    let onDelete: () -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .headline) private var buttonSize: CGFloat = 17
    @ScaledMetric(relativeTo: .headline) private var buttonLineHeight: CGFloat = 22
    @AccessibilityFocusState private var titleIsFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)

            ViewThatFits(in: .vertical) {
                panel.fixedSize(horizontal: false, vertical: true)
                ScrollView { panel.frame(maxWidth: .infinity) }
                    .scrollIndicators(.hidden)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("library.delete-confirmation")
        .accessibilityAction(.escape, onCancel)
        .onAppear { titleIsFocused = true }
    }

    private var panel: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                styledText("이 작업을 삭제하겠습니까?", font: "Pretendard-Bold",
                           size: titleSize, lineHeight: titleLineHeight, tracking: -0.26 * titleSize / 22)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleIsFocused)
                styledText("삭제된 작업은 복구할 수 없어요", font: "Pretendard-Regular",
                           size: bodySize, lineHeight: bodyLineHeight, tracking: -0.43 * bodySize / 17)
            }
            .foregroundStyle(Color("BrandNeutralBlack"))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            actions
        }
        .padding(20)
        .frame(maxWidth: 358)
        .background(Color("BrandNeutralWhite"), in: RoundedRectangle(cornerRadius: 44))
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button(role: .destructive, action: onDelete) {
                actionLabel("삭제하기")
                    .foregroundStyle(Color("AccentsRed"))
                    .background(Color("BrandNeutral50"), in: Capsule())
            }
            .accessibilityIdentifier("library.confirm-delete")

            Button(role: .cancel, action: onCancel) {
                actionLabel("취소")
                    .foregroundStyle(Color("BrandNeutralWhite"))
                    .background(Color("BrandMain500"), in: Capsule())
            }
            .accessibilityIdentifier("library.cancel-delete")
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(_ title: String) -> some View {
        styledText(title, font: "Pretendard-SemiBold", size: buttonSize,
                   lineHeight: buttonLineHeight, tracking: -0.43 * buttonSize / 17)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Capsule())
    }

    private func styledText(_ value: String, font: String, size: CGFloat,
                            lineHeight: CGFloat, tracking: CGFloat) -> some View {
        let uiFont = UIFont(name: font, size: size) ?? .systemFont(ofSize: size)
        let adjustment = max(0, lineHeight - uiFont.lineHeight)
        return Text(value)
            .font(.custom(font, fixedSize: size))
            .tracking(tracking)
            .lineSpacing(adjustment)
            .padding(.vertical, adjustment / 2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("보관함 작업 삭제 확인") {
    LibraryDeletionConfirmationView(onDelete: {}, onCancel: {})
}
#endif
