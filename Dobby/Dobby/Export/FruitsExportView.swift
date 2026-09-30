import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FruitsExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var opening = false
    @State private var alertMessage: String?
    @State private var copiedMessage = ""
    @State private var showCopyFields = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("후루츠패밀리 앱을 열어주세요").font(.title2.bold())
                    Text("옷 정보를 내보내기 위해서는 직접 열어주셔야해요")
                        .font(.subheadline)
                    Button {
                        opening = true
                        Task {
                            let started = await controller.start(product: product)
                            guard !Task.isCancelled else { opening = false; return }
                            if started {
                                // 도우미 시작 중 사용자가 다른 앱으로 이동했다면 다시 전환시키지 않는다.
                                if phase == .active { openFruits() }
                                else { opening = false }
                            }
                            else {
                                opening = false
                                showCopyFields = true
                                alertMessage = controller.errorMessage
                            }
                        }
                    } label: {
                        HStack {
                            if opening { ProgressView().tint(.white) }
                            Text("후루츠패밀리 열기").font(.body.weight(.semibold))
                        }.frame(maxWidth: .infinity).padding(.vertical, 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.orange, in: Capsule())
                    .disabled(opening || controller.busy)
                    .accessibilityIdentifier("export.fruits.open")
                }.padding(24).padding(.bottom, 16)
                Color(.systemGroupedBackground).frame(height: 8)
                VStack(alignment: .leading, spacing: 20) {
                    keyboardGuide
                    ShortcutCopySetupSection()
                    Text("어떻게 내보내나요?").font(.title2.bold())
                    step(1, "게시글 작성 화면으로 이동해주세요")
                    step(2, "다이나믹 아일랜드를 길게 누른 뒤 복사해주세요")
                    islandIllustration
                        .padding(.horizontal, 12)
                    step(3, "각 입력 항목에 붙여넣기해주세요")
                    DisclosureGroup("상품 정보 직접 복사", isExpanded: $showCopyFields) {
                        ForEach(ProductCopyField.allCases) { field in
                            copyButton(field.title, value: product.fruits.value(for: field))
                        }
                        copyButton("가격 · \(product.fruits.price)원", value: product.fruits.price)
                        copyButton("총장 · \(product.fruits.length) cm", value: product.fruits.length)
                        copyButton("허리 단면 · \(product.fruits.waist) cm", value: product.fruits.waist)
                        copyButton("허벅지 단면 · \(product.fruits.thigh) cm", value: product.fruits.thigh)
                        Text("실측 전체 복사는 하나의 문장입니다. 개별 입력란에는 위 숫자를 각각 복사해주세요.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("후루츠패밀리 앱 열기") { opening = true; openFruits() }
                            .disabled(opening || controller.busy)
                    }.padding(.top, 16)
                    if !copiedMessage.isEmpty { Text(copiedMessage).font(.caption).foregroundStyle(.secondary) }
                    if controller.session != nil {
                        Button("복사 도우미 종료", role: .destructive) { Task { await controller.stop() } }
                            .disabled(controller.busy || opening)
                        Text("이 화면을 닫아도 복사 도우미는 유지됩니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("후루츠패밀리로 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(.primary) }
                    .accessibilityLabel("채널 선택으로 돌아가기").disabled(opening || controller.busy)
            }
        }
        .onAppear { controller.refresh() }
        .onChange(of: phase) { _, value in if value == .active { controller.refresh() } }
        .alert("안내", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("확인", role: .cancel) { alertMessage = nil }
        } message: { Text(alertMessage ?? "") }
    }

    // 웹으로 열린 것을 앱 실행 성공으로 오인하지 않도록 Universal Link 앱 연결만 요청한다.
    private func openFruits() {
        UIApplication.shared.open(ExportChannel.fruitsFamily.destinationURL, options: [.universalLinksOnly: true]) { accepted in
            Task { @MainActor in
                opening = false
                if accepted { onOpened() }
                else {
                    let helper = controller.session != nil ? " 복사 도우미는 유지됩니다." : " 아래에서 상품 정보를 직접 복사할 수 있어요."
                    alertMessage = "후루츠패밀리 앱으로 연결하지 못했어요. 앱이 설치되어 있다면 홈 화면에서 직접 열어주세요." + helper
                }
            }
        }
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                copiedMessage = "복사할 정보가 없어요"; return
            }
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [.localOnly: true])
            copiedMessage = "\(title) · 입력란에 붙여넣어주세요"
        } label: { Label(title, systemImage: "doc.on.doc") }
            .padding(.vertical, 6)
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)").font(.body.weight(.semibold)).frame(width: 36, height: 36).fixedSize()
                .background(Color.orange.opacity(0.3), in: Circle())
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyboardGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dobby 키보드로 바로 입력", systemImage: "keyboard")
                .font(.headline)
            Text("최초 1회: iPhone 설정 > 일반 > 키보드 > 키보드 > 새로운 키보드 추가에서 'Dobby 상품 입력'을 추가해주세요.")
            Text("후루츠 입력란을 누른 뒤 키보드의 🌐를 길게 눌러 Dobby를 선택하고, 상품명·설명·가격·실측 버튼을 누르세요.")
            Text("전체 접근 허용은 켜지 않아도 됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(18)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
    }

    private var islandIllustration: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Dobby").foregroundStyle(.white).font(.caption)
                Spacer()
                Circle().fill(.mint).frame(width: 5, height: 5)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) { ProductCopyControlLabel(field: .productName); ProductCopyControlLabel(field: .description) }
                HStack(spacing: 8) { ProductCopyControlLabel(field: .brand); ProductCopyControlLabel(field: .measurements) }
            }
        }.padding(18).background(.black, in: RoundedRectangle(cornerRadius: 34))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("다이나믹 아일랜드 안내 이미지. 제품명, 설명, 브랜드명, 실측 사이즈 복사 버튼")
    }
}
