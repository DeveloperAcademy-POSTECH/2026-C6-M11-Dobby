import SwiftUI

struct FruitsPhotoSaveSection: View {
    let isSaving: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("선택한 사진들을 기기에 저장해주세요")
                .font(.custom("Pretendard-Bold", fixedSize: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            FruitsPhotoSaveButton(isSaving: isSaving, onSave: onSave)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

private struct FruitsPhotoSaveButton: View {
    let isSaving: Bool
    let onSave: () -> Void

    var body: some View {
        Button(action: onSave) {
            Text("저장하기")
                .font(.custom("Pretendard-Medium", fixedSize: 16))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 26.5)
                .padding(.vertical, 14)
                .background(.brandMain500)
                .foregroundColor(.brandNeutralWhite)
                .clipShape(.rect(cornerRadius: 60))
        }
    }
}

#Preview("기본") {
    FruitsPhotoSaveSection(isSaving: false, onSave: { })
}

#Preview("저장 중") {
    FruitsPhotoSaveSection(isSaving: true, onSave: { })
}
