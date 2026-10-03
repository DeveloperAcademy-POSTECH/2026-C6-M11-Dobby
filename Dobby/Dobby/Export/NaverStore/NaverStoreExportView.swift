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
        Form {
            Section("등록할 상품") {
                LabeledContent("상품명", value: product.name)
                TextField("판매 가격 · 10원 이상 입력", text: $priceText).keyboardType(.numberPad)
                Text("판매 가격은 10원 이상 입력해 주세요.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("사진", value: product.imageData == nil ? "없음" : "1장")
            }
            Section("카테고리") {
                if let selectedCategory {
                    LabeledContent("선택됨", value: selectedCategory.wholeCategoryName)
                }
                if categories.isEmpty {
                    Button("카테고리 불러오기") { Task { await searchCategories() } }
                }
            }
            Section("추천 카테고리") {
                Text("촬영 시 저장한 의류 종류를 참고한 후보입니다. 성별과 세부 종류를 확인해 선택해 주세요.")
                    .font(.caption).foregroundStyle(.secondary)
                if recommendations.isEmpty {
                    Text("추천 정보가 없어요. 전체 탐색이나 검색으로 선택해 주세요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(recommendations) { category in categoryButton(category) }
            }
            Section("카테고리 검색") {
                TextField("예: 여성 청바지, 남성 재킷", text: $categoryQuery)
                if !categoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if searchResults.isEmpty { Text("검색 결과가 없어요. 다른 단어로 검색해 주세요.") }
                    ForEach(searchResults) { category in categoryButton(category) }
                }
            }
            Section("전체 카테고리 탐색") {
                Text(categoryPath.isEmpty ? "패션의류 또는 패션잡화를 선택해 주세요." : categoryPath.joined(separator: " > "))
                    .font(.caption).foregroundStyle(.secondary)
                if !categoryPath.isEmpty {
                    Button("이전 분류로") { categoryPath.removeLast() }
                }
                ForEach(childNames, id: \.self) { name in
                    Button {
                        let next = categoryPath + [name]
                        if let leaf = categories.first(where: { parts($0) == next }) {
                            selectedCategory = leaf
                        } else { categoryPath = next }
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            Image(systemName: selectedCategory.map { parts($0) == categoryPath + [name] } == true
                                  ? "checkmark.circle.fill" : "chevron.right")
                        }
                    }
                }
            }
            Section("상품 고시 정보") {
                TextField("소재", text: $material)
                TextField("색상", text: $color)
                TextField("사이즈", text: $size)
            }
            Section {
                Text("테스트 상품은 재고 1개·중고·판매 중지 및 전시 중지 상태로 등록됩니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("네이버 스마트스토어에 등록") { Task { await publish() } }
                    .frame(maxWidth: .infinity)
                    .disabled(isWorking || selectedCategory == nil || product.imageData == nil || (Int(priceText) ?? 0) < 10)
            }
        }
        .navigationTitle("네이버스토어 내보내기")
        .navigationBarTitleDisplayMode(.inline)
        .task { await searchCategories() }
        .overlay { if isWorking { ProgressView().controlSize(.large) } }
        .alert(isError ? "등록할 수 없습니다" : "등록 완료",
               isPresented: Binding(get: { resultMessage != nil }, set: { if !$0 { resultMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: { Text(resultMessage ?? "") }
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

    private func categoryButton(_ category: NaverCategory) -> some View {
        Button { selectedCategory = category } label: {
            HStack {
                Text(category.wholeCategoryName)
                Spacer()
                if selectedCategory?.id == category.id { Image(systemName: "checkmark.circle.fill") }
            }
        }.foregroundStyle(.primary)
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
