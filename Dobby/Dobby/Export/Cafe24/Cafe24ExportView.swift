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
        ExportScreenContent {
            ExportServiceHeader(
                channel: .cafe24,
                title: "카페24",
                description: "연결한 쇼핑몰에 상품 정보를 바로 등록해요.",
                status: connectedMallID == nil ? nil : "연결됨"
            )

            ExportSectionCard(
                title: "쇼핑몰 연결",
                subtitle: connectedMallID == nil ? "상품을 등록할 카페24 쇼핑몰 ID를 입력해 주세요." : nil
            ) {
                if let connectedMallID {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ExportScreenStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("연결된 쇼핑몰")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(connectedMallID)
                                .font(.headline)
                        }
                        Spacer()
                        ExportStatusBadge(title: "사용 가능")
                    }
                    .padding(16)
                    .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))

                    Button("다른 쇼핑몰 연결") { self.connectedMallID = nil }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ExportScreenStyle.accent)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(ExportScreenStyle.accent.opacity(0.08), in: Capsule())
                } else {
                    ExportField(label: "쇼핑몰 ID") {
                        TextField("예: myshop", text: $mallID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .exportTextFieldStyle()
                    }
                    ChakPrimaryButton(title: "카페24 계정 연결", isLoading: isWorking) {
                        Task { await connect() }
                    }
                        .disabled(isWorking || mallID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ExportSectionCard(title: "등록할 상품") {
                ExportProductSummary(product: product)
                Divider()
                ExportField(label: "판매가") {
                    HStack(spacing: 8) {
                        TextField("판매가 입력", text: $priceText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("원")
                            .foregroundStyle(.secondary)
                    }
                    .exportTextFieldStyle()
                }
                ExportInfoBanner(
                    text: "첫 등록은 고객에게 노출되지 않도록 진열 안 함·판매 안 함 상태로 등록됩니다.",
                    systemImage: "eye.slash.fill"
                )
            }
        }
        .navigationTitle("카페24 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExportBottomActionBar {
                ExportBottomAction(
                    title: "카페24에 상품 등록",
                    isWorking: isWorking,
                    isEnabled: connectedMallID != nil && !priceText.filter(\.isNumber).isEmpty
                ) {
                    Task { await publish() }
                }
            }
        }
        .overlay { if isWorking { ExportLoadingOverlay(message: "카페24와 연결 중…") } }
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
