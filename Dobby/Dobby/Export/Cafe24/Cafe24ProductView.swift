import SwiftUI
import UIKit

struct Cafe24ProductView: View {
    @Binding var draft: Cafe24ExportDraft
    let isCompleted: Bool
    let isDisabled: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isCompleted {
                    Cafe24CompletionHeader()
                }
                Cafe24ProductPhotos(photos: draft.photos)
                Cafe24ProductNameField(text: $draft.productName) {
                    draft.resetProductName()
                }
                .disabled(areFieldsDisabled)
                Cafe24ProductDescriptionField(text: $draft.productDescription) {
                    draft.resetProductDescription()
                }
                .disabled(areFieldsDisabled)
                Cafe24PriceField(priceText: $draft.priceText) {
                    draft.resetPrice()
                }
                .disabled(areFieldsDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 116)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.brandNeutral50).ignoresSafeArea())
    }

    private var areFieldsDisabled: Bool { isDisabled || isCompleted }
}

private struct Cafe24CompletionHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("카페24에 업로드 완료 🎉")
                .font(.title3.bold())
            HStack(spacing: 0) {
                Text("연결된 계정에 자동 업로드를 ")
                Text("완료")
                    .foregroundStyle(Color(.brandMain500))
                Text("했어요")
            }
            .font(.body)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct Cafe24ProductPhotos: View {
    let photos: [Data]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("업로드할 사진")
                .font(.headline)

            Cafe24PhotoStrip(photos: photos)
        }
    }
}

private struct Cafe24PhotoStrip: View {
    let photos: [Data]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                if photos.isEmpty {
                    Cafe24ProductPhoto(data: nil)
                } else {
                    ForEach(photos.indices, id: \.self) { index in
                        Cafe24ProductPhoto(data: photos[index])
                    }
                }
            }
        }
    }
}

private struct Cafe24ProductPhoto: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "tshirt")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 212)
        .background(Color(.brandNeutral100))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct Cafe24ProductNameField: View {
    @Binding var text: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "상품명", onReset: onReset)
            TextField("상품명 입력", text: $text)
                .font(.body)
                .foregroundStyle(Color(.brandNeutral800))
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct Cafe24ProductDescriptionField: View {
    @Binding var text: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "상품 설명", onReset: onReset)
            TextEditor(text: $text)
                .font(.body)
                .foregroundStyle(Color(.brandNeutral800))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 140)
                .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct Cafe24PriceField: View {
    @Binding var priceText: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Cafe24EditorHeader(title: "판매가", onReset: onReset)
            Cafe24PriceInput(priceText: $priceText)
        }
    }
}

private struct Cafe24PriceInput: View {
    @Binding var priceText: String

    var body: some View {
        HStack(spacing: 8) {
            TextField("판매가 입력", text: $priceText)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
            Text("원")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Cafe24EditorHeader: View {
    let title: String
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .bottom) {
            Cafe24EditorTitle(title: title)
            Spacer()
            Cafe24ResetButton(action: onReset)
        }
    }
}

private struct Cafe24EditorTitle: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.medium))
            Text("눌러서 직접 글을 수정할 수 있어요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Cafe24ResetButton: View {
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
