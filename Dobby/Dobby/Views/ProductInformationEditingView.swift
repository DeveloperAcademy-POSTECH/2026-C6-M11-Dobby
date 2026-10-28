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
                      allowsPhotoEditing: true, onExit: requestExit, onComplete: onComplete)
            .alert("저장하지 않은 변경사항이 있어요", isPresented: $showsDiscardConfirmation) {
                Button("닫기", role: .cancel) { }
                Button("삭제하고 나가기", role: .destructive, action: discardChangesAndExit)
            } message: {
                Text("변경사항을 삭제하고 보관함으로 나갈까요?")
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
