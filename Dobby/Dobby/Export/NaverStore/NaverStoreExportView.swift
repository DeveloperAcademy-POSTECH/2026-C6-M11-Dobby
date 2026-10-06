import SwiftUI

struct NaverStoreExportView: View {
    let product: ExportProduct
    @State private var client = NaverStoreIntegrationClient()
    @State private var priceText: String
    @State private var categoryQuery = ""
    @State private var categories: [NaverCategory] = []
    @State private var selectedCategory: NaverCategory?
    @State private var categoryPath: [String] = []
    @State private var material = "상품 상세 참조"
    @State private var color = "상품 상세 참조"
    @State private var size = "상품 상세 참조"
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
                channel: .naverStore,
                title: "네이버 스마트스토어",
                description: "상품 정보와 카테고리를 확인하고 스토어에 등록해요.",
                status: selectedCategory == nil ? nil : "카테고리 선택 완료"
            )

            ExportSectionCard(title: "등록할 상품") {
                ExportProductSummary(product: product)
                Divider()
                ExportField(label: "판매 가격") {
                    HStack(spacing: 8) {
                        TextField("10원 이상 입력", text: $priceText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                        Text("원")
                            .foregroundStyle(.secondary)
                    }
                    .exportTextFieldStyle()
                }
                if product.imageData == nil {
                    ExportInfoBanner(
                        text: "상품을 등록하려면 대표 사진이 필요해요.",
                        systemImage: "photo.badge.exclamationmark",
                        tint: .red
                    )
                }
            }

            categorySelection
            categoryExplorer
            productNotice

            ExportInfoBanner(
                text: "테스트 상품은 재고 1개·중고·판매 중지 및 전시 중지 상태로 등록됩니다.",
                systemImage: "eye.slash.fill"
            )

            if let validationMessage {
                ExportInfoBanner(text: validationMessage, systemImage: "exclamationmark.circle.fill", tint: .red)
            }
        }
        .navigationTitle("네이버스토어 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .task { await searchCategories() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExportBottomActionBar {
                ExportBottomAction(
                    title: "네이버 스마트스토어에 등록",
                    isWorking: isWorking,
                    isEnabled: canPublish
                ) {
                    Task { await publish() }
                }
            }
        }
        .overlay { if isWorking { ExportLoadingOverlay(message: "스토어 정보를 확인 중…") } }
        .alert(isError ? "등록할 수 없습니다" : "등록 완료",
               isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(resultMessage ?? "") }
    }

    private var categorySelection: some View {
        ExportSectionCard(
            title: "카테고리 선택",
            subtitle: "촬영한 의류 종류를 바탕으로 찾은 추천 카테고리예요."
        ) {
            if let selectedCategory {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(ExportScreenStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("선택한 카테고리")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(selectedCategory.wholeCategoryName)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ExportScreenStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: ExportScreenStyle.fieldCornerRadius))
            }

            if categories.isEmpty {
                Button { Task { await searchCategories() } } label: {
                    Label("카테고리 불러오기", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(ExportScreenStyle.accent, in: Capsule())
            } else if recommendations.isEmpty {
                Text("추천 정보가 없어요. 검색하거나 전체 카테고리에서 선택해 주세요.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 10)], spacing: 10) {
                    ForEach(recommendations) { category in
                        recommendationButton(category)
                    }
                }
            }

            Divider()

            ExportField(label: "카테고리 검색") {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("예: 여성 청바지, 남성 재킷", text: $categoryQuery)
                        .textInputAutocapitalization(.never)
                }
                .exportTextFieldStyle()
            }

            if !categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searchResults.isEmpty {
                    Text("검색 결과가 없어요. 다른 단어로 검색해 주세요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(searchResults) { category in
                            categoryButton(category)
                        }
                    }
                }
            }
        }
    }

    private var categoryExplorer: some View {
        ExportSectionCard(
            title: "전체 카테고리 탐색",
            subtitle: categoryPath.isEmpty ? "패션의류 또는 패션잡화부터 선택해 주세요." : categoryPath.joined(separator: "  ›  ")
        ) {
            if !categoryPath.isEmpty {
                Button { categoryPath.removeLast() } label: {
                    Label("이전 분류", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(ExportScreenStyle.accent)
            }

            VStack(spacing: 8) {
                ForEach(childNames, id: \.self) { name in
                    categoryPathButton(name)
                }
            }
        }
    }

    private var productNotice: some View {
        ExportSectionCard(
            title: "상품 고시 정보",
            subtitle: "구매자가 확인할 기본 상품 정보를 입력해 주세요."
        ) {
            ExportField(label: "소재") {
                TextField("예: 상품 상세 참조", text: $material)
                    .exportTextFieldStyle()
            }
            ExportField(label: "색상") {
                TextField("예: 상품 상세 참조", text: $color)
                    .exportTextFieldStyle()
            }
            ExportField(label: "사이즈") {
                TextField("예: 상품 상세 참조", text: $size)
                    .exportTextFieldStyle()
            }
        }
    }

    private func searchCategories() async {
        isWorking = true; defer { isWorking = false }
        do {
            categories = try await client.searchCategories(query: "")
            if categories.isEmpty {
                isError = true
                resultMessage = "일치하는 최종 카테고리를 찾지 못했습니다."
            }
        } catch { show(error) }
    }

    private func parts(_ category: NaverCategory) -> [String] {
        category.wholeCategoryName.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var childNames: [String] {
        Array(Set(categories.compactMap { category -> String? in
            let path = parts(category)
            guard path.count > categoryPath.count, Array(path.prefix(categoryPath.count)) == categoryPath else { return nil }
            return path[categoryPath.count]
        })).sorted()
    }

    private var searchResults: [NaverCategory] {
        let words = categoryQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return categories.filter { category in words.allSatisfy { category.wholeCategoryName.localizedCaseInsensitiveContains($0) } }
    }

    private var recommendations: [NaverCategory] {
        guard let hint = product.garmentCategory else { return [] }
        let mapping = ["Jeans": ["청바지"], "Shorts": ["반바지"], "Long Pants": ["바지"],
                       "바지": ["바지"], "상의": ["티셔츠", "셔츠", "니트"],
                       "T-shirt": ["티셔츠"], "Shirt": ["셔츠"], "Polo": ["티셔츠"],
                       "Sweater": ["니트"], "Hoodie": ["후드"], "Jacket": ["재킷"],
                       "Blazer": ["재킷"], "Denim Jacket": ["재킷"], "Sports Jacket": ["재킷"],
                       "Coat": ["코트"], "Skirt": ["스커트"], "Dresses": ["원피스"]]
        guard let words = mapping[hint] else { return [] }
        return Array(categories.filter { category in
            parts(category).first == "패션의류" && words.contains(where: { category.name.contains($0) })
        }.sorted { $0.wholeCategoryName < $1.wholeCategoryName }.prefix(8))
    }

    private var canPublish: Bool {
        !isWorking && selectedCategory != nil && product.imageData != nil && (Int(priceText) ?? 0) >= 10
    }

    private var validationMessage: String? {
        if product.imageData == nil { return "대표 사진을 추가해야 등록할 수 있어요." }
        if (Int(priceText) ?? 0) < 10 { return "판매 가격을 10원 이상 입력해 주세요." }
        if selectedCategory == nil { return "상품 카테고리를 선택해 주세요." }
        return nil
    }

    private func categoryButton(_ category: NaverCategory) -> some View {
        Button { selectedCategory = category } label: {
            HStack(spacing: 12) {
                Text(category.wholeCategoryName)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: selectedCategory?.id == category.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedCategory?.id == category.id ? ExportScreenStyle.accent : Color.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func recommendationButton(_ category: NaverCategory) -> some View {
        let isSelected = selectedCategory?.id == category.id
        return Button { selectedCategory = category } label: {
            HStack(spacing: 6) {
                if isSelected { Image(systemName: "checkmark") }
                Text(shortCategoryName(category))
                    .lineLimit(2)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.white : ExportScreenStyle.label)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 10)
            .background(isSelected ? ExportScreenStyle.accent : ExportScreenStyle.field, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.wholeCategoryName)
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
    }

    private func shortCategoryName(_ category: NaverCategory) -> String {
        parts(category).suffix(2).joined(separator: " · ")
    }

    private func categoryPathButton(_ name: String) -> some View {
        let next = categoryPath + [name]
        let leaf = categories.first(where: { parts($0) == next })
        let isSelected = leaf?.id == selectedCategory?.id
        return Button {
            if let leaf {
                selectedCategory = leaf
            } else {
                categoryPath = next
            }
        } label: {
            HStack(spacing: 12) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : leaf == nil ? "chevron.right" : "circle")
                    .foregroundStyle(isSelected ? ExportScreenStyle.accent : Color.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(ExportScreenStyle.field, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func publish() async {
        guard let category = selectedCategory else { show(NaverStoreIntegrationError.missingCategory); return }
        guard let price = Int(priceText), price >= 10 else { show(NaverStoreIntegrationError.invalidPrice); return }
        isWorking = true; defer { isWorking = false }
        do {
            let result = try await client.publish(product: product, price: price, category: category,
                                                  material: material, color: color, size: size)
            isError = false
            resultMessage = "상품 #\(result.smartstoreChannelProductNo)을 판매 중지 및 전시 중지 상태로 등록했습니다."
        } catch { show(error) }
    }

    private func show(_ error: Error) {
        isError = true
        resultMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

#Preview { NavigationStack { NaverStoreExportView(product: .demo) } }
