import SwiftUI

struct InstagramComposeView: View {
    let account: InstagramAccount
    @Binding var draft: InstagramExportDraft
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                InstagramAccountCard(account: account)
                InstagramPhotoEditor(draft: $draft)
                InstagramCaptionEditor(draft: $draft)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 116)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.brandNeutral50).ignoresSafeArea())
        .disabled(isDisabled)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct InstagramPhotoEditor: View {
    @Binding var draft: InstagramExportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InstagramEditorHeader(title: "업로드할 사진", resetAction: { draft.resetPhotos() })
            if draft.photos.isEmpty {
                ContentUnavailableView("업로드할 사진이 없어요", systemImage: "photo.badge.exclamationmark",
                                       description: Text("초기화를 누르면 상품 사진을 다시 불러옵니다."))
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(draft.photos) { photo in
                            InstagramDraftPhotoCell(photo: photo) { draft.removePhoto(id: photo.id) }
                        }
                    }
                }
            }
        }
    }
}

private struct InstagramDraftPhotoCell: View {
    let photo: InstagramDraftPhoto
    let onRemove: () -> Void

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
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityLabel("업로드 목록에서 사진 삭제")
        }
    }
}

private struct InstagramCaptionEditor: View {
    @Binding var draft: InstagramExportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("캡션").font(.body.weight(.medium))
                    Text("눌러서 직접 글을 수정할 수 있어요")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                InstagramResetButton(action: { draft.resetCaption() })
            }
            TextEditor(text: $draft.caption)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 260)
                .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityValue("\(draft.caption.utf16.count) / 2,200자")
        }
    }
}

private struct InstagramEditorHeader: View {
    let title: String
    let resetAction: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.body.weight(.medium))
            Spacer()
            InstagramResetButton(action: resetAction)
        }
    }
}

private struct InstagramResetButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("초기화", systemImage: "arrow.clockwise")
                .font(.subheadline)
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
