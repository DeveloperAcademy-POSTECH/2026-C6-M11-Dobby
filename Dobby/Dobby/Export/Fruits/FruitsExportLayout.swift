import SwiftUI

struct FruitsExportLayout: View {
    let product: ExportProduct
    let isSavingPhotos: Bool
    let hasSavedPhotos: Bool
    let onSave: () -> Void
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            FruitsExportBody(
                product: product,
                isSavingPhotos: isSavingPhotos,
                hasSavedPhotos: hasSavedPhotos,
                onSave: onSave,
                onCopy: onCopy
            )
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                FruitsExportBody(
                    product: product,
                    isSavingPhotos: isSavingPhotos,
                    hasSavedPhotos: hasSavedPhotos,
                    onSave: onSave,
                    onCopy: onCopy
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FruitsExportBody: View {
    let product: ExportProduct
    let isSavingPhotos: Bool
    let hasSavedPhotos: Bool
    let onSave: () -> Void
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FruitsPhotoSaveSection(
                isSaving: isSavingPhotos,
                hasSaved: hasSavedPhotos,
                onSave: onSave
            )

            if hasSavedPhotos {
                FruitsExportContent(product: product, onCopy: onCopy)
                    .padding(.top, 28)
            }
        }
    }
}

#Preview("저장 전") {
    FruitsExportLayout(
        product: .fruitsPreview,
        isSavingPhotos: false,
        hasSavedPhotos: false,
        onSave: { },
        onCopy: { _ in }
    )
}

#Preview("저장 완료") {
    FruitsExportLayout(
        product: .fruitsPreview,
        isSavingPhotos: false,
        hasSavedPhotos: true,
        onSave: { },
        onCopy: { _ in }
    )
}

#Preview("작은 화면 - 긴 내용") {
    FruitsExportLayout(
        product: .fruitsLongPreview,
        isSavingPhotos: false,
        hasSavedPhotos: true,
        onSave: { },
        onCopy: { _ in }
    )
    .frame(height: 500)
}
