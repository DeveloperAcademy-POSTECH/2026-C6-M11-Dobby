import SwiftUI
import UIKit

struct FruitsExportView: View {
    let product: ExportProduct
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(ToastPresenter.self) private var toastPresenter
    @State private var pipController = MeasurementPiPController()
    @State private var opening: Bool
    @State private var alertMessage: String?

    init(
        product: ExportProduct,
        onOpened: @escaping () -> Void = { },
        initialOpening: Bool = false
    ) {
        self.product = product
        self.onOpened = onOpened
        _opening = State(initialValue: initialOpening)
    }

    var body: some View {
        ZStack {
            MeasurementPiPSourceView(controller: pipController)
                .frame(
                    width: MeasurementPiPView.renderSize.width,
                    height: MeasurementPiPView.renderSize.height
                )
                .accessibilityHidden(true)
            FruitsExportLayout(
                product: product,
                onCopy: copy
            )
        }
        .background(Color(.brandNeutralWhite).ignoresSafeArea())
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ExportNavigationButton(
                    systemImage: "xmark",
                    accessibilityLabel: "채널 선택으로 돌아가기",
                    isDisabled: opening
                ) {
                    pipController.stop()
                    dismiss()
                }
            }
            ToolbarItem(placement: .principal) {
                FruitsTransferIndicator()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FruitsExportBottomAction(isLoading: opening) {
                startPiPAndOpenFruits()
            }
        }
        .onDisappear {
            if phase == .active {
                pipController.stop()
            }
        }
        .alert("안내", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func copy(_ field: ProductCopyField) {
        ClipboardWriter().copyText(product.marketplacePayload.value(for: field))
        toastPresenter.show(field.fruitsToastMessage)
    }

    private func startPiPAndOpenFruits() {
        opening = true
        Task {
            do {
                try await pipController.start(measurements: product.exportMeasurements)
                guard !Task.isCancelled else { opening = false; return }
                if phase == .active {
                    openFruits()
                } else {
                    opening = false
                }
            } catch {
                opening = false
                alertMessage = error.localizedDescription
            }
        }
    }

    private func openFruits() {
        UIApplication.shared.open(
            ExportChannel.fruitsFamily.destinationURL,
            options: [.universalLinksOnly: true]
        ) { accepted in
            Task { @MainActor in
                opening = false
                if accepted {
                    onOpened()
                } else {
                    alertMessage = "후루츠패밀리 앱으로 연결하지 못했어요. 앱이 설치되어 있다면 홈 화면에서 직접 열어주세요."
                }
            }
        }
    }
}

private struct FruitsExportBottomAction: View {
    let isLoading: Bool
    let action: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChakPrimaryButton(title: "후루츠패밀리 열기", isLoading: isLoading) {
                action()
            }
                .disabled(isLoading)
                .accessibilityIdentifier("export.fruits.open")
        }
        .padding(.horizontal, 33)
        .padding(.top, 16)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.brandNeutralWhite))
    }
}

#Preview("기본") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview)
    }
    .toast()
}

#Preview("긴 내용") {
    NavigationStack {
        FruitsExportView(product: .fruitsLongPreview)
    }
    .toast()
}

#Preview("앱 여는 중") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview, initialOpening: true)
    }
    .toast()
}

private extension ProductCopyField {
    var fruitsToastMessage: String {
        switch self {
        case .productName: "제품명을 복사했어요"
        case .description: "설명을 복사했어요"
        case .brand: "브랜드를 복사했어요"
        case .measurements: "실측 사이즈를 복사했어요"
        }
    }
}
