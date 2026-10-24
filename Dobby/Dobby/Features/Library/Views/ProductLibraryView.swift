import SwiftUI
import SwiftData

struct ProductLibraryView: View {
    @Environment(\.modelContext) private var context
    let garments: [Garment]
    @Binding var isEditing: Bool
    let onStartMeasurement: () -> Void
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var pendingDeletion: PendingDeletion?
    @State private var deletionFailed = false
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 33
    @ScaledMetric(relativeTo: .title2) private var emptyTitleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var emptyDescriptionLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .callout) private var emptyButtonHeight: CGFloat = 50

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    private var filteredGarments: [Garment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return garments }
        return garments.filter {
            $0.name.localizedStandardContains(query) || $0.brand.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 20)
                .padding(.top, 5)

            Group {
                if garments.isEmpty {
                    emptyLibrary
                } else if filteredGarments.isEmpty {
                    ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(filteredGarments) { garment in
                                productCell(garment)
                            }
                        }
                        .padding(.top, isEditing ? 16 : 0)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("library.products")
                }
            }
            .padding(.top, isEditing ? 0 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(LibraryStyle.background.ignoresSafeArea())
        .navigationTitle("보관함")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Text("보관함")
                    .font(.custom("Pretendard-Bold", size: 24, relativeTo: .title2))
                    .tracking(-0.24)
                    .foregroundStyle(LibraryStyle.primary)
                    .fixedSize()
                    .frame(minHeight: titleLineHeight)
                    .accessibilityAddTraits(.isHeader)
                    .onTapGesture { isSearchFocused = false }
            }
            .sharedBackgroundVisibility(.hidden)

            // Keep the navigation item's title for routing while showing the custom leading title.
            ToolbarItem(placement: .principal) {
                Text("")
                    .accessibilityHidden(true)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isSearchFocused = false
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isEditing.toggle()
                    }
                } label: {
                    Text(isEditing ? "완료" : "수정")
                        .frame(minWidth: garments.isEmpty ? 37 : nil)
                }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(garments.isEmpty ? .white : LibraryStyle.primary)
                    .disabled(garments.isEmpty)
                    .accessibilityIdentifier("library.edit-mode")
            }
        }
        .alert("정말 삭제하시겠습니까?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { product in
            Button("취소", role: .cancel) { pendingDeletion = nil }
            Button("삭제", role: .destructive) {
                deleteProduct(id: product.id)
            }
        } message: { product in
            Text("\(product.name) 상품을 보관함에서 삭제합니다.")
        }
        .alert("상품을 삭제하지 못했어요", isPresented: $deletionFailed) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("상품이 삭제되지 않았어요. 다시 시도해 주세요.")
        }
        .onChange(of: garments.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { isEditing = false }
        }
        .onDisappear {
            isSearchFocused = false
            isEditing = false
            pendingDeletion = nil
        }
    }

    private var emptyLibrary: some View {
        GeometryReader { geometry in
            let contentHeight = emptyTitleLineHeight + emptyDescriptionLineHeight + emptyButtonHeight + 32
            // Keep the design's position above center while adapting to the available height.
            let topSpacing = max(0, geometry.size.height - contentHeight) * 0.37

            ScrollView {
                VStack(spacing: 0) {
                    Text("보관함이 비어있어요")
                        .font(.title2.bold())
                        .tracking(-0.26)
                        .foregroundStyle(LibraryStyle.primary)
                        .frame(minHeight: emptyTitleLineHeight)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("library.empty.title")

                    Text("작업을 시작해보세요")
                        .font(.body)
                        .tracking(-0.43)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: emptyDescriptionLineHeight)
                        .padding(.top, 8)

                    Button(action: onStartMeasurement) {
                        Text("실측 시작하기")
                            .font(.callout.weight(.semibold).italic())
                            .tracking(-0.31)
                            .foregroundStyle(LibraryStyle.background)
                            .padding(.horizontal, 24)
                            .frame(minWidth: 146, minHeight: emptyButtonHeight)
                            .background(Color("HomeAccent"), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .accessibilityIdentifier("library.empty.start-measurement")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, topSpacing)
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func productCell(_ garment: Garment) -> some View {
        if isEditing {
            ProductLibraryCard(garment: garment)
                .overlay(alignment: .topLeading) {
                    Button(role: .destructive) {
                        pendingDeletion = PendingDeletion(id: garment.id,
                            name: garment.name.isEmpty ? "선택한" : garment.name)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 9.589, weight: .semibold))
                            .foregroundStyle(LibraryStyle.primary)
                            .frame(width: 25, height: 25)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: -17.5, y: -16.5)
                    .accessibilityLabel("\(garment.name.isEmpty ? "상품" : garment.name) 삭제")
                    .accessibilityIdentifier("library.delete.\(garment.id.uuidString)")
                }
                .accessibilityElement(children: .contain)
        } else {
            NavigationLink(value: garment.id) {
                ProductLibraryCard(garment: garment)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("library.product.\(garment.id.uuidString)")
        }
    }

    private func deleteProduct(id: UUID) {
        pendingDeletion = nil
        do {
            try GarmentStore.deleteSavedGarment(id: id, in: context.container)
        } catch {
            deletionFailed = true
        }
    }

    private struct PendingDeletion {
        let id: UUID
        let name: String
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .frame(width: 21)
                .foregroundStyle(LibraryStyle.primary)
                .accessibilityHidden(true)

            TextField(text: $searchText, prompt: Text("Search")
                .foregroundStyle(Color(red: 191.0 / 255, green: 191.0 / 255, blue: 191.0 / 255))) {
                Text("보관함 검색")
            }
                .font(.system(size: 17))
                .foregroundStyle(LibraryStyle.primary)
                .tint(.blue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFocused = false }
                .accessibilityLabel("보관함 검색")
                .accessibilityHint("제품명이나 브랜드로 검색합니다.")
                .accessibilityIdentifier("library.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, searchText.isEmpty ? 16 : 2)
        .frame(minHeight: 48)
        .background(.white, in: Capsule())
    }
}

#if DEBUG
private struct ProductLibraryPreview: View {
    @Query(sort: \Garment.updatedAt, order: .reverse) private var garments: [Garment]
    @State var isEditing = false

    var body: some View {
        NavigationStack {
            ProductLibraryView(garments: garments, isEditing: $isEditing, onStartMeasurement: {})
        }
    }
}

#Preview("보관함 그리드") {
    ProductLibraryPreview()
        .modelContainer(LibraryPreviewData.makeContainer())
        .tint(LibraryStyle.primary)
        .preferredColorScheme(.light)
}

#Preview("보관함 · 수정 모드") {
    ProductLibraryPreview(isEditing: true)
        .modelContainer(LibraryPreviewData.makeContainer())
        .tint(LibraryStyle.editAccent)
        .preferredColorScheme(.light)
}

#Preview("보관함 · 비어 있음") {
    ProductLibraryPreview()
        .modelContainer(for: [Garment.self, GarmentPhoto.self, LandmarkPoint.self,
            MeasuredValue.self, ExportRecord.self], inMemory: true)
        .tint(LibraryStyle.primary)
        .preferredColorScheme(.light)
}
#endif
