import SwiftUI

struct Cafe24ExportView: View {
    let product: ExportProduct
    @State private var client = Cafe24IntegrationClient()
    @State private var mallID = ""
    @State private var priceText: String
    @State private var connectedMallID: String?
    @State private var isWorking = false
    @State private var resultMessage: String?
    @State private var isError = false

    init(product: ExportProduct) {
        self.product = product
        _priceText = State(initialValue: product.fruits.price)
    }

    var body: some View {
        Form {
            Section("카페24 계정") {
                if let connectedMallID {
                    LabeledContent("연결된 쇼핑몰", value: connectedMallID)
                    Button("다른 쇼핑몰 연결") { self.connectedMallID = nil }
                } else {
                    TextField("쇼핑몰 ID", text: $mallID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("카페24 계정 연결") { Task { await connect() } }
                        .disabled(isWorking || mallID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("등록할 상품") {
                LabeledContent("상품명", value: product.name)
                TextField("판매가", text: $priceText).keyboardType(.numberPad)
                LabeledContent("사진", value: product.imageData == nil ? "없음" : "1장")
                Text("첫 테스트는 고객에게 노출되지 않도록 진열 안 함·판매 안 함 상태로 등록됩니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("카페24에 상품 등록") { Task { await publish() } }
                    .frame(maxWidth: .infinity).disabled(isWorking || connectedMallID == nil)
            }
        }
        .navigationTitle("카페24 내보내기").navigationBarTitleDisplayMode(.inline)
        .overlay { if isWorking { ProgressView().controlSize(.large) } }
        .task { await loadStatus() }
        .alert(isError ? "등록할 수 없습니다" : "등록 완료",
               isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(resultMessage ?? "") }
    }

    private func loadStatus() async {
        guard client.isConfigured else { return }
        if let status = try? await client.connectionStatus() { connectedMallID = status.connected ? status.mallID : nil }
    }

    private func connect() async {
        isWorking = true; defer { isWorking = false }
        do {
            try await client.connect(mallID: mallID)
            connectedMallID = try await client.connectionStatus().mallID
        } catch { show(error) }
    }

    private func publish() async {
        guard let price = Int(priceText.filter(\.isNumber)) else { show(Cafe24IntegrationError.invalidPrice); return }
        isWorking = true; defer { isWorking = false }
        do {
            let result = try await client.publish(product: product, price: price)
            isError = false
            resultMessage = "\(result.mallID) 쇼핑몰에 상품 #\(result.productNo)을 비공개로 등록했습니다."
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        isError = true
        resultMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#Preview { NavigationStack { Cafe24ExportView(product: .demo) } }
