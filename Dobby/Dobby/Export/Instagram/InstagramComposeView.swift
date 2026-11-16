import SwiftUI

struct InstagramComposeView: View {
    let account: InstagramAccount
    @Binding var draft: InstagramExportDraft
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 24) {
                InstagramAccountCard(account: account)
                InstagramPhotoEditor(photos: draft.photos)
                    .disabled(isDisabled)
                InstagramCaptionEditor(draft: $draft)
                    .disabled(isDisabled)
                    .frame(maxWidth: 363)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.brandNeutralWhite).ignoresSafeArea())
    }
}

private struct InstagramAccountCard: View {
    let account: InstagramAccount

    var body: some View {
        ExportUploadAccountCard(accountLabel: "@\(account.username)") {
            InstagramProfileImage(url: account.profilePictureURL)
        }
    }
}

private struct InstagramPhotoEditor: View {
    let photos: [InstagramDraftPhoto]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("업로드할 사진")
                .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                .foregroundStyle(Color(.brandNeutral950))
                .frame(maxWidth: 363, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            GeometryReader { geometry in
                let horizontalInset = max(0, (geometry.size.width - 363) / 2)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            InstagramDraftPhotoCell(photo: photo)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("업로드할 상품 사진 \(index + 1)")
                                .accessibilityValue("전체 \(photos.count)장")
                                .accessibilityAddTraits(.isImage)
                        }
                    }
                }
                .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
            }
            .frame(height: 212)
        }
    }
}

private struct InstagramDraftPhotoCell: View {
    let photo: InstagramDraftPhoto

    var body: some View {
        Group {
            if let image = UIImage(data: photo.data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 212)
        .background(Color(.brandNeutral100))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct InstagramCaptionEditor: View {
    @Binding var draft: InstagramExportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InstagramCaptionHeader(onReset: { draft.resetCaption() })
            InstagramCaptionInput(text: $draft.caption)

            if let validationMessage = draft.validationMessage,
               draft.photos.isEmpty == false {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct InstagramCaptionHeader: View {
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("캡션")
                    .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                    .foregroundStyle(Color(.brandNeutral950))
                    .accessibilityAddTraits(.isHeader)
                Text("눌러서 직접 글을 수정할 수 있어요")
                    .font(.custom("Pretendard-Regular", fixedSize: 14))
                    .foregroundStyle(Color(.brandNeutral700))
            }
            Spacer()
            InstagramResetButton(action: onReset)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct InstagramCaptionInput: View {
    @Binding var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("Pretendard-Regular", fixedSize: 17))
                .foregroundStyle(Color(.label))
                .lineLimit(1...)
                .accessibilityLabel("인스타그램 캡션")
                .accessibilityHint("업로드할 게시물의 글을 수정합니다.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct InstagramResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                Text("초기화")
                    .font(.custom("Pretendard-Regular", fixedSize: 14))
            }
                .foregroundStyle(Color(.brandNeutral800))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("캡션 초기화")
        .accessibilityHint("수정한 캡션을 원래 상품 정보로 되돌립니다.")
    }
}

struct InstagramProfileImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(ExportScreenStyle.accent)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .accessibilityHidden(true)
    }
}

#Preview("사진 3장 · 캡션 편집") {
    @Previewable @State var draft = InstagramExportDraft(product: .instagramPreview)

    InstagramComposeView(
        account: .preview,
        draft: $draft,
        isDisabled: false
    )
}

#Preview("계정 카드", traits: .sizeThatFitsLayout) {
    InstagramAccountCard(account: .preview)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("프로필 이미지", traits: .sizeThatFitsLayout) {
    InstagramProfileImage(url: nil)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("업로드할 사진", traits: .sizeThatFitsLayout) {
    let draft = InstagramExportDraft(product: .instagramPreview)

    InstagramPhotoEditor(photos: draft.photos)
        .frame(width: 402, height: 246)
        .background(Color(.brandNeutralWhite))
}

#Preview("사진 셀", traits: .sizeThatFitsLayout) {
    let draft = InstagramExportDraft(product: .instagramPreview)

    if let photo = draft.photos.first {
        InstagramDraftPhotoCell(photo: photo)
            .padding()
            .background(Color(.brandNeutralWhite))
    }
}

#Preview("캡션 편집", traits: .sizeThatFitsLayout) {
    @Previewable @State var draft = InstagramExportDraft(product: .instagramPreview)

    InstagramCaptionEditor(draft: $draft)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("캡션 제목", traits: .sizeThatFitsLayout) {
    InstagramCaptionHeader(onReset: {})
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("캡션 입력란", traits: .sizeThatFitsLayout) {
    @Previewable @State var text = "90s 나이키 자켓\n\n가격: 89,000원"

    InstagramCaptionInput(text: $text)
        .frame(width: 363)
        .padding()
        .background(Color(.brandNeutralWhite))
}

#Preview("초기화 버튼", traits: .sizeThatFitsLayout) {
    InstagramResetButton(action: {})
        .padding()
        .background(Color(.brandNeutralWhite))
}
