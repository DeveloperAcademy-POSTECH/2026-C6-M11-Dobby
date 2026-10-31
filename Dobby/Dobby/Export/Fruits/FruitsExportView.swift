import SwiftUI
import UIKit

struct FruitsExportView: View {
    let product: ExportProduct
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var pipController = MeasurementPiPController()
    @State private var isSavingPhotos: Bool
    @State private var hasSavedPhotos: Bool
    @State private var opening: Bool
    @State private var alertMessage: String?

    init(
        product: ExportProduct,
        onOpened: @escaping () -> Void = { },
        initialIsSavingPhotos: Bool = false,
        initialHasSavedPhotos: Bool = false,
        initialOpening: Bool = false
    ) {
        self.product = product
        self.onOpened = onOpened
        _isSavingPhotos = State(initialValue: initialIsSavingPhotos)
        _hasSavedPhotos = State(initialValue: initialHasSavedPhotos)
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
            VStack(spacing: 0) {
                FruitsPhotoSaveSection(isSaving: isSavingPhotos, onSave: savePhotos)

                if hasSavedPhotos {
                    FruitsExportContent(product: product, onCopy: copy)
                        .padding(.top, 28)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(.white)
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
            if hasSavedPhotos {
                ChakPrimaryButton(title: "후루츠패밀리 열기", isLoading: opening) {
                    startPiPAndOpenFruits()
                }
                .disabled(opening)
                .accessibilityIdentifier("export.fruits.open")
                .padding(.horizontal, 33)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.white)
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
    }

    private func savePhotos() {
        isSavingPhotos = true
        Task {
            do {
                try await FruitsPhotoLibraryWriter().save(photos: product.exportPhotos)
                hasSavedPhotos = true
            } catch {
                alertMessage = error.localizedDescription
            }
            isSavingPhotos = false
        }
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

#Preview("저장 전") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview)
    }
}

#Preview("저장 중") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview, initialIsSavingPhotos: true)
    }
}

#Preview("저장 완료") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview, initialHasSavedPhotos: true)
    }
}

#Preview("저장 완료 - 긴 내용") {
    NavigationStack {
        FruitsExportView(product: .fruitsLongPreview, initialHasSavedPhotos: true)
    }
}

#Preview("앱 여는 중") {
    NavigationStack {
        FruitsExportView(
            product: .fruitsPreview,
            initialHasSavedPhotos: true,
            initialOpening: true
        )
    }
}
