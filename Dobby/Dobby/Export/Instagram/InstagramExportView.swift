import SwiftUI

struct InstagramExportView: View {
    let product: ExportProduct
    @State private var client = InstagramIntegrationClient()
    @State private var account: InstagramAccount?
    @State private var caption: String
    @State private var photoIndex = 0
    @State private var busy = false
    @State private var confirming = false
    @State private var message: String?
    @State private var published = false
    @State private var confirmingDisconnect = false
    @State private var requestID = UUID().uuidString

    init(product: ExportProduct) {
        self.product = product
        let payload = product.instagram
        _caption = State(initialValue: [payload.productName, payload.description, payload.brand,
                                        payload.measurements, payload.price.isEmpty ? "" : "가격: \(payload.price)원"]
            .filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    private var selectedPhoto: Data? {
        product.displayPhotos.indices.contains(photoIndex) ? product.displayPhotos[photoIndex] : nil
    }

    var body: some View {
        Form {
            Section("게시할 계정") {
                if let account {
                    LabeledContent("연결됨", value: "@\(account.username)")
                    Button("연결 해제", role: .destructive) { confirmingDisconnect = true }
                } else {
                    Text("게시할 Instagram 프로페셔널 계정을 연결해 주세요.")
                    Button("Instagram 계정 연결") { Task { await connect() } }
                }
                Button("연결 상태 새로고침") { Task { await loadAccount() } }
            }
            Section("사진 1장 선택") {
                if product.displayPhotos.count > 1 {
                    Picker("게시할 사진", selection: $photoIndex) {
                        ForEach(product.displayPhotos.indices, id: \.self) { index in
                            Text("사진 \(index + 1)").tag(index)
                        }
                    }
                }
                if let data = selectedPhoto,
                   let prepared = try? InstagramIntegrationClient.prepareImage(data),
                   let image = UIImage(data: prepared) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 300)
                } else { Text("게시할 사진이 없습니다.") }
                Text("사진 비율에 따라 흰 여백이 추가될 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("게시물 내용") {
                TextEditor(text: $caption).frame(minHeight: 180)
                Text("\(caption.utf16.count) / 2,200자")
                    .foregroundStyle(caption.utf16.count > 2200 ? .red : .secondary)
            }
            Section {
                Text("게시하면 연결된 계정에 사진 1장과 내용이 실제 공개됩니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(published ? "게시 완료" : "Instagram에 게시") { confirming = true }
                    .disabled(busy || published || account == nil || selectedPhoto == nil
                              || caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || caption.utf16.count > 2200)
            }
        }
        .disabled(busy || published)
        .navigationTitle("Instagram 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView("처리 중…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .task { await loadAccount() }
        .confirmationDialog("Instagram 연결을 해제할까요?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("연결 해제", role: .destructive) { Task { await disconnect() } }
            Button("취소", role: .cancel) {}
        } message: { Text("이 기기의 연결 정보가 서버에서 삭제됩니다. 기존 Instagram 게시물은 유지됩니다.") }
        .confirmationDialog("@\(account?.username ?? "")에 실제로 게시할까요?", isPresented: $confirming, titleVisibility: .visible) {
            Button("공개 게시하기") { Task { await publish() } }
            Button("취소", role: .cancel) {}
        } message: { Text("선택한 사진과 내용이 Instagram에 공개됩니다.") }
        .alert(published ? "게시 완료" : "Instagram 안내", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            } message: { Text(message ?? "") }
    }

    private func loadAccount() async {
        busy = true
        defer { busy = false }
        do { account = try await client.account() }
        catch { account = nil; message = error.localizedDescription }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        do { account = try await client.connect(); requestID = UUID().uuidString }
        catch { message = error.localizedDescription }
    }

    private func disconnect() async {
        busy = true
        defer { busy = false }
        do { try await client.disconnect(); account = nil; requestID = UUID().uuidString }
        catch { message = error.localizedDescription }
    }

    private func publish() async {
        guard let photo = selectedPhoto, let expected = account else { return }
        busy = true
        defer { busy = false }
        do {
            let current = try await client.account()
            guard current?.id == expected.id else {
                account = current
                message = "연결 계정이 변경되었습니다. 게시할 계정을 다시 확인해 주세요."
                return
            }
            let result = try await client.publish(image: photo, caption: caption, accountID: expected.id, requestID: requestID)
            published = true
            message = "@\(result.username)에 게시했습니다.\n게시물 ID: \(result.mediaID)"
        } catch { message = error.localizedDescription }
    }
}
