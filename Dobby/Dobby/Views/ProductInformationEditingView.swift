import SwiftData
import SwiftUI

struct ProductInformationEditingView: View {
    @Bindable var session: ProductInformationEditSession
    let onExit: () -> Void
    let onDiscard: () -> Void
    let onComplete: (Garment) -> Void
    var onAIGenerationPresentationChange: ((ProductAutofillLoadingPresentation?) -> Void)? = nil

    @State private var showsDiscardConfirmation = false

    var body: some View {
        InfoInputView(garment: session.garment, measurementInput: $session.measurementInput,
                      allowsPhotoEditing: true, onExit: requestExit,
                      onGenerateAI: { try await session.generateInformation() },
                      onCancelGeneration: { session.cancelGeneration() },
                      onAIGenerationPresentationChange: onAIGenerationPresentationChange,
                      onComplete: onComplete)
            .environment(\.modelContext, session.context)
            .fullScreenCover(isPresented: $showsDiscardConfirmation) {
                ProductInformationDiscardConfirmation(
                    onCancel: { setDiscardConfirmationVisible(false) },
                    onDiscard: discardChangesAndExit
                )
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
            }
    }

    private func requestExit() {
        guard session.hasChanges else {
            onExit()
            return
        }
        setDiscardConfirmationVisible(true)
    }

    private func discardChangesAndExit() {
        setDiscardConfirmationVisible(false)
        session.discard()
        onDiscard()
    }

    private func setDiscardConfirmationVisible(_ isVisible: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showsDiscardConfirmation = isVisible
        }
    }
}

#if DEBUG
private struct ProductInformationEditingPreview: View {
    let garment: Garment
    let showsConfirmation: Bool
    @State private var measurementInput = GarmentMeasurementInputState()

    var body: some View {
        ZStack {
            NavigationStack {
                InfoInputView(garment: garment, measurementInput: $measurementInput,
                              allowsPhotoEditing: true, onExit: { })
                    .disabled(showsConfirmation)
            }

            if showsConfirmation {
                ProductInformationDiscardConfirmation(onCancel: { }, onDiscard: { })
            }
        }
    }
}

#Preview("제품 정보 수정") {
    ProductInformationEditingPreview(
        garment: SampleData.first(in: SampleData.previewContainer.mainContext),
        showsConfirmation: false
    )
    .modelContainer(SampleData.previewContainer)
    .preferredColorScheme(.light)
}

#Preview("제품 정보 수정 · 변경 취소 경고") {
    ProductInformationEditingPreview(
        garment: SampleData.first(in: SampleData.previewContainer.mainContext),
        showsConfirmation: true
    )
    .modelContainer(SampleData.previewContainer)
    .preferredColorScheme(.light)
}
#endif
