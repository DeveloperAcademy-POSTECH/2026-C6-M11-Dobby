import SwiftUI
import UIKit

struct FruitsExportGuideSheet: View {
    let product: ExportProduct
    let controller: CopyActivityController
    let onOpened: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var opening = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 36, weight: .light))
                        Text("다이나믹 아일랜드를\n꾹 눌러보세요")
                            .font(.title3)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)

                    FruitsExportGuideContent(
                        opening: opening,
                        busy: controller.busy,
                        onOpen: startAndOpenFruits
                    )
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("후루츠패밀리로 내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: dismissIfPossible) {
                        Image(systemName: "xmark")
                    }
                    .disabled(opening || controller.busy)
                    .accessibilityLabel("가이드 닫기")
                    .accessibilityIdentifier("export.fruits.sheet.close")
                }
            }
        }
        .accessibilityIdentifier("export.fruits.sheet")
        .presentationDetents([.fraction(0.72), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(opening || controller.busy)
        .onAppear { controller.refresh() }
        .onChange(of: phase) { _, value in
            if value == .active { controller.refresh() }
        }
        .alert("안내", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func startAndOpenFruits() {
        opening = true
        Task {
            let started = await controller.start(product: product)
            guard !Task.isCancelled else {
                opening = false
                return
            }
            guard started else {
                opening = false
                alertMessage = controller.errorMessage
                return
            }
            if phase == .active {
                openFruits()
            } else {
                opening = false
            }
        }
    }

    private func openFruits() {
        UIApplication.shared.open(
            ExportChannel.fruitsFamily.destinationURL,
            options: [.universalLinksOnly: true]
        ) { accepted in
            Task { @MainActor in
                opening = false
                if accepted {
                    onOpened()
                } else {
                    let helper = controller.session != nil ? " 복사 도우미는 유지됩니다." : ""
                    alertMessage = "후루츠패밀리 앱으로 연결하지 못했어요. 앱이 설치되어 있다면 홈 화면에서 직접 열어주세요." + helper
                }
            }
        }
    }

    private func dismissIfPossible() {
        guard !opening, !controller.busy else { return }
        dismiss()
    }
}

private struct FruitsExportGuideContent: View {
    let opening: Bool
    let busy: Bool
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    guideStep(1) {
                        Text("**후루츠패밀리**의 게시글 작성 화면으로\n이동해주세요")
                    }

                    Text("옷 정보를 내보내기 위해서는 직접 열어주셔야해요")
                        .font(.subheadline)
                }

                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        if opening { ProgressView().tint(.white) }
                        Text("후루츠패밀리 열기")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 62)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color("BrandMain"), in: Capsule())
                .disabled(opening || busy)
                .accessibilityIdentifier("export.fruits.sheet.open")
            }

            guideStep(2) {
                Text("다이나믹 아일랜드를 클릭해서 값을\n복사해주세요")
            }
            guideStep(3) {
                Text("후루츠패밀리의 입력 항목에 붙여넣기해주세요")
            }
            guideStep(4) {
                Text("모든 값들을 하나씩 반복해주세요")
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }

    private func guideStep<Content: View>(
        _ number: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color("BrandMain"), in: Circle())

            content()
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

#Preview {
    FruitsExportGuideSheet(
        product: .demo,
        controller: CopyActivityController(),
        onOpened: {}
    )
}
