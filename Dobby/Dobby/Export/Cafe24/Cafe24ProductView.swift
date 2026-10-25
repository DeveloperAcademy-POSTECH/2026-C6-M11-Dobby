import SwiftUI
import UIKit

struct Cafe24ProductView: View {
    let mallID: String
    let product: ExportProduct
    @Binding var priceText: String
    let isCompleted: Bool
    let isDisabled: Bool
    let onReportProblem: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if isCompleted {
                    Cafe24CompletionHeader(onReportProblem: onReportProblem)
                }
                Cafe24AccountCard(mallID: mallID)
                Cafe24ProductPhoto(product: product)
                Cafe24ReadOnlyField(title: "상품명", value: productName)
                Cafe24ReadOnlyField(title: "상품 설명", value: productDescription, isMultiline: true)
                Cafe24PriceField(priceText: $priceText, isDisabled: isDisabled || isCompleted)
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

    private var productName: String {
        product.name.isEmpty ? "이름 없는 상품" : product.name
    }

    private var productDescription: String {
        let values = [product.fruits.description, product.fruits.measurements].filter { !$0.isEmpty }
        return values.isEmpty ? "등록된 상품 설명이 없어요." : values.joined(separator: "\n\n")
    }
}

private struct Cafe24CompletionHeader: View {
    let onReportProblem: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("카페24에 업로드 완료 🎉")
                .font(.title3.bold())
            HStack(spacing: 0) {
                Text("연결된 계정에 자동 업로드를 ")
                Text("완료")
                    .foregroundStyle(Color(.brandMain))
                Text("했어요")
            }
            .font(.body)
            Button("정상적으로 업로드가 안됐어요", action: onReportProblem)
                .font(.caption)
                .foregroundStyle(.primary)
                .underline()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct Cafe24AccountCard: View {
    let mallID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("이 계정으로 상품을 올릴게요")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image("Cafe24Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .background(.white, in: Circle())
                Text("@\(mallID).cafe24.com")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct Cafe24ProductPhoto: View {
    let product: ExportProduct

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("업로드할 사진")
                .font(.headline)

            Group {
                if let data = product.imageData, let image = UIImage(data: data) {
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
}

private struct Cafe24ReadOnlyField: View {
    let title: String
    let value: String
    var isMultiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.body)
                .foregroundStyle(Color(.brandNeutral800))
                .frame(maxWidth: .infinity, minHeight: isMultiline ? 108 : 52, alignment: .topLeading)
                .padding(16)
                .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct Cafe24PriceField: View {
    @Binding var priceText: String
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("판매가")
                .font(.headline)
            Text("카페24에 등록할 판매가를 입력해 주세요")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("판매가 입력", text: $priceText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .disabled(isDisabled)
                Text("원")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
