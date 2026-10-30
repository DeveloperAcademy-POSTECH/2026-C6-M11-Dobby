import SwiftData
import SwiftUI

struct ProductInformationEditingView: View {
    @Bindable var garment: Garment
    @Binding private var measurementInput: GarmentMeasurementInputState
    let onExit: () -> Void
    let onComplete: (Garment) -> Void

    @State private var initialSnapshot: ProductInformationEditSnapshot
    @State private var showsDiscardConfirmation = false

    init(garment: Garment, measurementInput: Binding<GarmentMeasurementInputState>,
         onExit: @escaping () -> Void, onComplete: @escaping (Garment) -> Void) {
        self.garment = garment
        _measurementInput = measurementInput
        self.onExit = onExit
        self.onComplete = onComplete
        _initialSnapshot = State(initialValue: ProductInformationEditSnapshot(
            garment: garment,
            measurementInput: measurementInput.wrappedValue
        ))
    }

    var body: some View {
        InfoInputView(garment: garment, measurementInput: $measurementInput,
                      allowsPhotoEditing: true,
                      onExit: requestExit, onComplete: onComplete)
            .fullScreenCover(isPresented: $showsDiscardConfirmation) {
                ProductInformationDiscardConfirmation(
                    onCancel: { showsDiscardConfirmation = false },
                    onDiscard: discardChangesAndExit
                )
                .presentationBackground(.clear)
                .interactiveDismissDisabled()
            }
    }

    private func requestExit() {
        guard initialSnapshot.hasChanges(in: garment, measurementInput: measurementInput) else {
            onExit()
            return
        }
        showsDiscardConfirmation = true
    }

    private func discardChangesAndExit() {
        showsDiscardConfirmation = false
        initialSnapshot.restore(garment, measurementInput: &measurementInput)
        onExit()
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
