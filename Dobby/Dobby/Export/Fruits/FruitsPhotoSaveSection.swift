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
            HStack(alignment: .center, spacing: 12) {
                if isSaving {
                    ProgressView()
                        .tint(Color("BrandNeutralWhite"))
                } else {
                    Text("저장하기")
                        .font(.custom("Pretendard-Medium", fixedSize: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color("BrandNeutralWhite"))
                }
            }
            .padding(.horizontal, 28)
            .frame(width: 108, height: 48)
            .background(Color("BrandMain100"))
            .clipShape(.rect(cornerRadius: 60))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(isSaving ? "사진 저장 중" : "사진 저장하기")
    }
}

#Preview("기본") {
    FruitsPhotoSaveSection(isSaving: false, onSave: { })
}

#Preview("저장 중") {
    FruitsPhotoSaveSection(isSaving: true, onSave: { })
}
