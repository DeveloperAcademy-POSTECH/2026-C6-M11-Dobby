import SwiftUI
import UIKit

struct FruitsExportView: View {
    let product: ExportProduct
    let controller: CopyActivityController
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var opening = false
    @State private var alertMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("후루츠패밀리 앱을 열어주세요")
                        .font(.title2.bold())
                    Text("옷 정보를 내보내기 위해서는 직접 열어주셔야해요")
                        .font(.subheadline.weight(.semibold))
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
                                alertMessage = controller.errorMessage
                            }
                        }
                    } label: {
                        HStack {
                            if opening { ProgressView().tint(.white) }
                            Text("후루츠패밀리 열기").font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color("BrandMain"), in: Capsule())
                    .padding(.top, 12)
                    .disabled(opening || controller.busy)
                    .accessibilityIdentifier("export.fruits.open")
                }
                .padding(.horizontal, 21)
                .padding(.top, 28)
                .padding(.bottom, 28)
                Color(.systemGroupedBackground).frame(height: 8)
                VStack(alignment: .leading, spacing: 20) {
                    Text("어떻게 내보내나요?").font(.title2.bold())
                    step(1, "게시글 작성 화면으로 이동해주세요")
                    step(2, "화면 상단부에 있는 다이나믹 아일랜드를 길게 눌러 펼쳐 주세요")
                    step(3, "원하는 버튼을 눌러 복사하세요")
                    Image("FruitsDynamicIslandGuide")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 17)
                        .accessibilityLabel("다이나믹 아일랜드에서 제품명, 설명과 실측 정보를 복사하는 화면")
                        .accessibilityIdentifier("export.fruits.guide")
                    step(4, "각 입력 항목에 붙여넣으세요")
                }
                .padding(.horizontal, 21)
                .padding(.top, 24)
                .padding(.bottom, 40)
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
                    let helper = controller.session != nil ? " 복사 도우미는 유지됩니다." : ""
                    alertMessage = "후루츠패밀리 앱으로 연결하지 못했어요. 앱이 설치되어 있다면 홈 화면에서 직접 열어주세요." + helper
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(Color("BrandMain300"), in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
