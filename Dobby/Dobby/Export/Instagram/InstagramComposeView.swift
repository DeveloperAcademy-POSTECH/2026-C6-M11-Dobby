import SwiftUI

struct InstagramComposeView: View {
    let account: InstagramAccount
    @Binding var draft: InstagramExportDraft
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 24) {
                InstagramAccountCard(account: account)
                    .frame(maxWidth: 363)
                    .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 12) {
            Text("이 계정으로 게시물을 올릴게요")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 11) {
                InstagramProfileImage(url: account.profilePictureURL)
                Text("@\(account.username)")
                    .font(.title3.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.brandNeutral50), in: RoundedRectangle(cornerRadius: 16))
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
            if photos.isEmpty {
                ContentUnavailableView("업로드할 사진이 없어요", systemImage: "photo.badge.exclamationmark")
                    .frame(maxWidth: 363, minHeight: 180)
                    .frame(maxWidth: .infinity)
            } else {
                GeometryReader { geometry in
                    let horizontalInset = max(0, (geometry.size.width - 363) / 2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(photos) { photo in
                                InstagramDraftPhotoCell(photo: photo)
                            }
                        }
                    }
                    .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
                }
                .frame(height: 212)
            }
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("캡션")
                    .font(.custom("Pretendard-SemiBold", fixedSize: 17))
                    .foregroundStyle(Color(.brandNeutral950))
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
