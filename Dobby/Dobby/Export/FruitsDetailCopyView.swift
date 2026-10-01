import SwiftUI
import UIKit

struct FruitsDetailCopyView: View {
    let product: ExportProduct
    let onOpened: () -> Void
    @State private var message = ""
    @State private var opening = false
    @State private var openFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("제품 사진").font(.headline)
                ExportProductHeader(product: product)
                field("제품 명", value: product.name)
                field("설명", value: product.fruits.description)
                field("브랜드", value: product.fruits.brand)
                field("가격", value: product.fruits.price)
                Text("실측 사이즈").font(.headline)
                VStack(spacing: 0) {
                    ForEach(product.copyMeasurements.filter { !$0.value.isEmpty }) { measurement in
                        HStack {
                            copyControl(measurement.title, value: measurement.value)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(measurement.value) cm").frame(maxWidth: .infinity)
                        }.padding(16)
                        Divider()
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                copyControl("실측 전체", value: product.fruits.measurements)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("copy.detail.feedback")
                Button("후루츠패밀리 열기") {
                    opening = true
                    UIApplication.shared.open(ExportChannel.fruitsFamily.destinationURL,
                                              options: [.universalLinksOnly: true]) { accepted in
                        Task { @MainActor in
                            opening = false
                            if accepted { onOpened() } else { openFailed = true }
                        }
                    }
                }
                .buttonStyle(.borderedProminent).tint(.orange).disabled(opening)
                Text("필요한 항목을 복사한 뒤 후루츠 입력란에 붙여넣어주세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .navigationTitle("제품 상세 페이지")
        .navigationBarTitleDisplayMode(.inline)
        .alert("후루츠패밀리를 열 수 없어요", isPresented: $openFailed) {
            Button("확인", role: .cancel) { }
        } message: { Text("앱이 설치되어 있다면 홈 화면에서 직접 열어주세요.") }
    }

    private func field(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            copyControl(title, value: value)
            Text(value.isEmpty ? "정보 없음" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func copyControl(_ title: String, value: String) -> some View {
        Button {
            ClipboardWriter().copyText(value)
            message = "\(title)이 복사되었습니다."
        } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.primary)
                Image(systemName: "doc.on.doc").foregroundStyle(.orange)
            }.frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityLabel("\(title) 복사")
    }
}
