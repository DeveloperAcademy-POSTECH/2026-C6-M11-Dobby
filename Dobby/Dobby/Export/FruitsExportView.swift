import SwiftUI
import UIKit

struct FruitsExportView: View {
    let product: ExportProduct
    let onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var pipController = MeasurementPiPController()
    @State private var copiedField: ProductCopyField?
    @State private var opening: Bool
    @State private var alertMessage: String?

    init(
        product: ExportProduct,
        onOpened: @escaping () -> Void = { },
        initialCopiedField: ProductCopyField? = nil,
        initialOpening: Bool = false
    ) {
        self.product = product
        self.onOpened = onOpened
        _copiedField = State(initialValue: initialCopiedField)
        _opening = State(initialValue: initialOpening)
    }

    var body: some View {
        ZStack {
            MeasurementPiPSourceView(controller: pipController)
                .frame(width: MeasurementPiPView.size.width, height: MeasurementPiPView.size.height)
                .accessibilityHidden(true)
            FruitsExportContent(product: product, copiedField: copiedField, onCopy: copy)
        }
        .background(.white)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ExportNavigationButton(
                    systemImage: "xmark",
                    accessibilityLabel: "채널 선택으로 돌아가기",
                    isDisabled: opening
                ) {
                    pipController.stop()
                    dismiss()
                }
            }
            ToolbarItem(placement: .principal) {
                FruitsTransferIndicator()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ChakPrimaryButton(title: "후루츠패밀리 열기", isLoading: opening) {
                startPiPAndOpenFruits()
            }
            .disabled(opening)
            .accessibilityIdentifier("export.fruits.open")
            .padding(.horizontal, 33)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.white)
        }
        .onDisappear {
            if phase == .active {
                pipController.stop()
            }
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

    private func copy(_ field: ProductCopyField) {
        ClipboardWriter().copyText(product.marketplacePayload.value(for: field))
        copiedField = field
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard copiedField == field else { return }
            copiedField = nil
        }
    }

    private func startPiPAndOpenFruits() {
        opening = true
        Task {
            do {
                try await pipController.start(measurements: product.exportMeasurements)
                guard !Task.isCancelled else { opening = false; return }
                if phase == .active {
                    openFruits()
                } else {
                    opening = false
                }
            } catch {
                opening = false
                alertMessage = error.localizedDescription
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
                    alertMessage = "후루츠패밀리 앱으로 연결하지 못했어요. 앱이 설치되어 있다면 홈 화면에서 직접 열어주세요."
                }
            }
        }
    }
}

private struct FruitsExportContent: View {
    let product: ExportProduct
    let copiedField: ProductCopyField?
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("복사 버튼을 누르고\n후루츠패밀리 판매 페이지를 열어주세요")
                    .font(.custom("Pretendard-Bold", fixedSize: 22))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 40)
                    .padding(.bottom, 14)

                FruitsCopyCard(product: product, copiedField: copiedField, onCopy: onCopy)

                Text("판매 페이지를 열고 제품명, 설명, 브랜드를 붙여 넣어주세요")
                    .padding(.top, 14)
                Text("· 실측 사이즈는 화면에 뜬 PiP를 보고 입력해 주세요")
                    .padding(.top, 4)
            }
            .font(.custom("Pretendard-Medium", fixedSize: 14))
            .foregroundStyle(Color("BrandNeutral500"))
            .padding(.horizontal, 21)
            .padding(.bottom, 24)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(.white)
    }
}

private struct FruitsCopyCard: View {
    let product: ExportProduct
    let copiedField: ProductCopyField?
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FruitsCopyFieldView(
                field: .productName,
                value: product.marketplacePayload.productName,
                isCopied: copiedField == .productName,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .description,
                value: product.marketplacePayload.description,
                isCopied: copiedField == .description,
                valueHeight: 100,
                onCopy: onCopy
            )
            Divider().overlay(Color("BrandNeutral200"))
            FruitsCopyFieldView(
                field: .brand,
                value: product.marketplacePayload.brand,
                isCopied: copiedField == .brand,
                onCopy: onCopy
            )
        }
        .padding(.horizontal, 16)
        .background(Color("BrandNeutral100"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct FruitsCopyFieldView: View {
    let field: ProductCopyField
    let value: String
    let isCopied: Bool
    var valueHeight: CGFloat? = nil
    let onCopy: (ProductCopyField) -> Void

    var body: some View {
        Button {
            onCopy(field)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: isCopied ? "checkmark" : "document.on.document")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color("BrandPrimary100"))
                }
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(field == .description ? 6 : 2)
                    .frame(maxWidth: .infinity, minHeight: valueHeight, alignment: .topLeading)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) 복사")
        .accessibilityValue(isCopied ? "복사됨" : value)
    }

    private var title: String {
        switch field {
        case .productName: "제품명"
        case .description: "설명"
        case .brand: "브랜드"
        case .measurements: "실측 사이즈"
        }
    }
}

private struct FruitsTransferIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            Image("FruitsExportSourceMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28.46, height: 8)
                .frame(width: 31, height: 31)
                .background(Color("BrandSub100"), in: RoundedRectangle(cornerRadius: 8))
            Image("FruitsExportArrow")
                .resizable()
                .frame(width: 13.5, height: 11)
            Image("FruitsFamailyLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 31, height: 31)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dobby에서 후루츠패밀리로 내보내기")
    }
}

#Preview("기본") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview)
    }
}

#Preview("긴 내용") {
    NavigationStack {
        FruitsExportView(product: .fruitsLongPreview)
    }
}

#Preview("복사 완료") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview, initialCopiedField: .description)
    }
}

#Preview("앱 여는 중") {
    NavigationStack {
        FruitsExportView(product: .fruitsPreview, initialOpening: true)
    }
}

private extension ExportProduct {
    static let fruitsPreview = ExportProduct(
        id: "fruits-preview",
        thumbnailData: nil,
        marketplacePayload: ProductCopyPayload(
            productName: "LEVI'S 550 보로 사시코 커스텀 팬츠",
            description: "빈티지한 워싱과 자연스러운 실루엣이 돋보이는 제품입니다.",
            brand: "LEVI'S",
            measurements: "",
            price: "56000",
            length: "68",
            waist: "",
            thigh: ""
        ),
        instagramPayload: .sample(for: .instagram),
        measurements: [
            ExportMeasurement(id: "shoulder", title: "어깨", value: "56"),
            ExportMeasurement(id: "chest", title: "가슴", value: "55"),
            ExportMeasurement(id: "length", title: "기장", value: "68"),
            ExportMeasurement(id: "sleeve", title: "소매", value: "52")
        ]
    )

    static let fruitsLongPreview = ExportProduct(
        id: "fruits-long-preview",
        thumbnailData: nil,
        marketplacePayload: ProductCopyPayload(
            productName: "아주 긴 제품명이 두 줄을 넘어가는 경우를 확인하기 위한 빈티지 오버사이즈 재킷",
            description: ProductCopyPayload.sample(for: .fruits).description,
            brand: "A VERY LONG VINTAGE BRAND NAME",
            measurements: "",
            price: "56000",
            length: "102",
            waist: "38",
            thigh: "32"
        ),
        instagramPayload: .sample(for: .instagram),
        measurements: [
            ExportMeasurement(id: "waist", title: "허리", value: "38"),
            ExportMeasurement(id: "rise", title: "밑위", value: "30"),
            ExportMeasurement(id: "thigh", title: "허벅지", value: "32"),
            ExportMeasurement(id: "hem", title: "밑단", value: "22"),
            ExportMeasurement(id: "length", title: "총장", value: "102")
        ]
    )
}
