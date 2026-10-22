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
        ExportScreenContent {
            ExportServiceHeader(
                channel: .instagram,
                title: "Instagram",
                description: "사진과 상품 설명을 연결된 계정에 게시해요.",
                status: published ? "게시 완료" : account.map { "@\($0.username)" }
            )

            ExportSectionCard(
                title: "게시할 계정",
                subtitle: account == nil ? "Instagram 프로페셔널 계정을 연결해 주세요." : nil
            ) {
                if let account {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(ExportScreenStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("연결된 계정")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("@\(account.username)")
                                .font(.headline)
                        }
                        Spacer()
                        ExportStatusBadge(title: "연결됨")
                    }
                    .padding(16)
                    .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))

                    HStack(spacing: 10) {
                        accountButton("새로고침", systemImage: "arrow.clockwise") {
                            Task { await loadAccount() }
                        }
                        accountButton("연결 해제", systemImage: "link.badge.minus", role: .destructive) {
                            confirmingDisconnect = true
                        }
                    }
                } else {
                    Button { Task { await connect() } } label: {
                        Label("Instagram 계정 연결", systemImage: "link")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(ExportScreenStyle.accent, in: Capsule())

                    Button { Task { await loadAccount() } } label: {
                        Label("연결 상태 새로고침", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ExportScreenStyle.accent)
                    .background(ExportScreenStyle.accent.opacity(0.08), in: Capsule())
                }
            }

            ExportSectionCard(
                title: "게시할 사진",
                subtitle: "게시물에 사용할 사진 1장을 선택해 주세요."
            ) {
                if let data = selectedPhoto,
                   let prepared = try? InstagramIntegrationClient.prepareImage(data),
                   let image = UIImage(data: prepared) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 360)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ContentUnavailableView(
                        "게시할 사진이 없어요",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("상품 사진을 추가한 뒤 다시 시도해 주세요.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }

                if product.displayPhotos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(product.displayPhotos.indices, id: \.self) { index in
                                photoThumbnail(at: index)
                            }
                        }
                    }
                }

                Label("사진 비율에 따라 흰 여백이 추가될 수 있어요.", systemImage: "aspectratio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExportSectionCard(title: "게시물 내용") {
                TextEditor(text: $caption)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 190)
                    .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
                Text("\(caption.utf16.count) / 2,200자")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(caption.utf16.count > 2200 ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ExportInfoBanner(
                text: "게시하면 연결된 계정에 선택한 사진과 내용이 실제로 공개됩니다.",
                systemImage: "globe"
            )
        }
        .disabled(busy || published)
        .navigationTitle("Instagram 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExportBottomActionBar {
                ExportBottomAction(
                    title: published ? "게시 완료" : "Instagram에 게시",
                    isWorking: busy,
                    isComplete: published,
                    isEnabled: canPublish
                ) {
                    confirming = true
                }
            }
        }
        .overlay { if busy { ExportLoadingOverlay(message: "Instagram과 연결 중…") } }
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

    private var canPublish: Bool {
        !busy && !published && account != nil && selectedPhoto != nil
            && !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && caption.utf16.count <= 2200
    }

    private func accountButton(_ title: String, systemImage: String,
                               role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : ExportScreenStyle.accent)
        .background(
            (role == .destructive ? Color.red : ExportScreenStyle.accent).opacity(0.08),
            in: Capsule()
        )
    }

    private func photoThumbnail(at index: Int) -> some View {
        Button { photoIndex = index } label: {
            Group {
                if let image = UIImage(data: product.displayPhotos[index]) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 70)
            .background(ExportScreenStyle.field)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(photoIndex == index ? ExportScreenStyle.accent : Color.clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("사진 \(index + 1)")
        .accessibilityValue(photoIndex == index ? "선택됨" : "선택 안 됨")
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
        guard selectedPhoto != nil, let expected = account else { return }
        let photos = InstagramIntegrationClient.publishingOrder(product.displayPhotos, selectedIndex: photoIndex)
        busy = true
        defer { busy = false }
        do {
            let current = try await client.account()
            guard current?.id == expected.id else {
                account = current
                message = "연결 계정이 변경되었습니다. 게시할 계정을 다시 확인해 주세요."
                return
            }
            let result = try await client.publish(images: photos, caption: caption,
                                                  accountID: expected.id, requestID: requestID)
            published = true
            message = "@\(result.username)에 게시했습니다.\n게시물 ID: \(result.mediaID)"
        } catch { message = error.localizedDescription }
    }
}
