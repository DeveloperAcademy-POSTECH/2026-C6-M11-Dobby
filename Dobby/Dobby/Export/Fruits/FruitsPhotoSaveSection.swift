import SwiftUI

struct FruitsPhotoSaveSection: View {
    let isSaving: Bool
    let hasSaved: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("선택한 사진들을 기기에 저장해주세요")
                .font(.custom("Pretendard-Bold", fixedSize: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            FruitsPhotoSaveControl(
                isSaving: isSaving,
                hasSaved: hasSaved,
                onSave: onSave
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
    }
}

private struct FruitsPhotoSaveControl: View {
    let isSaving: Bool
    let hasSaved: Bool
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FruitsPhotoSaveButton(hasSaved: hasSaved, onSave: onSave)

            if isSaving {
                FruitsPhotoSavingIndicator()
            } else if hasSaved {
                FruitsPhotoSavedIndicator()
            }
        }
    }
}

private struct FruitsPhotoSaveButton: View {
    let hasSaved: Bool
    let onSave: () -> Void

    var body: some View {
        Button(action: onSave) {
            Text(hasSaved ? "저장 완료" : "저장하기")
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

private struct FruitsPhotoSavingIndicator: View {
    @State private var rotation = 90.0

    var body: some View {
        Image(systemName: "progress.indicator")
            .font(.system(size: 26.27272, weight: .semibold))
            .foregroundStyle(.brandMain500)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 450
                }
            }
    }
}

private struct FruitsPhotoSavedIndicator: View {
    var body: some View {
        Image(systemName: "square.and.arrow.down.badge.checkmark")
            .font(.system(size: 26.27272, weight: .semibold))
            .foregroundStyle(.brandMain500)
            .rotationEffect(.degrees(90))
    }
}

#Preview("기본") {
    FruitsPhotoSaveSection(isSaving: false, hasSaved: false, onSave: { })
}

#Preview("저장 중") {
    FruitsPhotoSaveSection(isSaving: true, hasSaved: false, onSave: { })
}

#Preview("저장 완료") {
    FruitsPhotoSaveSection(isSaving: false, hasSaved: true, onSave: { })
}
