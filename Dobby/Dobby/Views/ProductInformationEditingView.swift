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
        ZStack {
            InfoInputView(garment: garment, measurementInput: $measurementInput,
                          allowsPhotoEditing: true, onExit: requestExit, onComplete: onComplete)
                .disabled(showsDiscardConfirmation)

            if showsDiscardConfirmation {
                ProductInformationDiscardConfirmation(
                    onCancel: { showsDiscardConfirmation = false },
                    onDiscard: discardChangesAndExit
                )
            }
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
        initialSnapshot.restore(garment, measurementInput: &measurementInput)
        onExit()
    }
}
