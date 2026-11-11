import SwiftUI
import SwiftData

struct ProductLibraryView: View {
    @Environment(\.modelContext) private var context
    let garments: [Garment]
    @Binding var isEditing: Bool
    let onStartMeasurement: () -> Void
    let onResumeDraft: (UUID) -> Void
    @State private var searchText = ""
    @State private var showsOnlyDrafts: Bool
    @State private var isSearchFocused = false
    @State private var pendingDeletion: UUID?
    @State private var deletionFailed = false
    @State private var searchRevealID = 0
    @State private var headerMetrics = LibraryHeaderMetrics()
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 33
    @ScaledMetric(relativeTo: .title2) private var emptyTitleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var emptyDescriptionLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .callout) private var emptyButtonHeight: CGFloat = 50

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top)
    ]

    init(garments: [Garment], isEditing: Binding<Bool>,
         onStartMeasurement: @escaping () -> Void,
         onResumeDraft: @escaping (UUID) -> Void = { _ in },
         initiallyShowsOnlyDrafts: Bool = false) {
        self.garments = garments
        _isEditing = isEditing
        self.onStartMeasurement = onStartMeasurement
        self.onResumeDraft = onResumeDraft
        _showsOnlyDrafts = State(initialValue: initiallyShowsOnlyDrafts)
    }

    private var filteredGarments: [Garment] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return garments }
        return garments.filter {
            $0.name.localizedStandardContains(query) || $0.brand.localizedStandardContains(query)
        }
    }

    private var filteredDraftGarments: [Garment] {
        filteredGarments.filter(\.isCreationDraft)
    }

    private var draftGarments: [Garment] {
        garments.filter(\.isCreationDraft)
    }

    private var filteredSavedGarments: [Garment] {
        filteredGarments.filter { !$0.isCreationDraft }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if garments.isEmpty {
                    emptyLibrary
                        .padding(.top, headerMetrics.statusBarHeight + headerMetrics.height + 16)
                        .padding(.bottom, headerMetrics.bottomBarHeight)
                } else if filteredGarments.isEmpty && !showsOnlyDrafts {
                    ContentUnavailableView.search(text: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .padding(.top, headerMetrics.statusBarHeight + headerMetrics.height + 16)
                        .padding(.bottom, headerMetrics.bottomBarHeight)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if !isEditing {
                                ForEach(filteredDraftGarments) { garment in
                                    draftCell(garment)
                                }
                            }

                            if !draftGarments.isEmpty {
                                ProductDraftCountBadge(
                                    count: draftGarments.count,
                                    isSelected: showsOnlyDrafts
                                ) {
                                    isSearchFocused = false
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        showsOnlyDrafts.toggle()
                                    }
                                }
                            }

                            if showsOnlyDrafts {
                                if filteredDraftGarments.isEmpty {
                                    ContentUnavailableView.search(
                                        text: searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    )
                                    .frame(maxWidth: .infinity)
                                } else {
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                        ForEach(filteredDraftGarments) { garment in
                                            draftProductCell(garment)
                                        }
                                    }
                                }
                            } else if !filteredSavedGarments.isEmpty {
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(filteredSavedGarments) { garment in
                                        productCell(garment)
                                    }
                                }
                            }
                        }
                        .padding(.top, headerMetrics.statusBarHeight + headerMetrics.height + 16)
                        .padding(.horizontal, 20)
                        .padding(.bottom, headerMetrics.bottomBarHeight + 24)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollEdgeEffectHidden(true, for: .top)
                    .accessibilityIdentifier("library.products")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(headerMetrics.height > 0 ? 1 : 0)
        .ignoresSafeArea(.container, edges: .top)
        .background(LibraryStyle.background.ignoresSafeArea())
        .navigationTitle("보관함")
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(LibraryStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                if isEditing {
                    Button("완료") {
                        setEditing(false)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.system(size: 17, weight: .medium))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(LibraryStyle.editAccent, in: Capsule())
                    .accessibilityIdentifier("library.edit-mode")
                } else {
                    Button("수정") {
                        setEditing(true)
                    }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LibraryStyle.primary)
                    .disabled(garments.isEmpty)
                    .accessibilityIdentifier("library.edit-mode")
                }
            }
            .sharedBackgroundVisibility(isEditing ? .hidden : .automatic)
        }
        .background {
            LibraryNavigationSearch(
                text: $searchText,
                isFocused: Binding(get: { isSearchFocused }, set: { isSearchFocused = $0 }),
                allowsHiding: !garments.isEmpty,
                revealID: searchRevealID,
                metrics: $headerMetrics
            )
            LibraryDeletionConfirmation(productID: $pendingDeletion, onDelete: deleteProduct)
        }
        .alert("상품을 삭제하지 못했어요", isPresented: $deletionFailed) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("상품이 삭제되지 않았어요. 다시 시도해 주세요.")
        }
        .onChange(of: garments.isEmpty, initial: true) { _, isEmpty in
            if isEmpty { isEditing = false }
        }
        .onChange(of: isEditing) { _, _ in searchRevealID += 1 }
        .onChange(of: draftGarments.isEmpty) { _, draftsAreEmpty in
            if draftsAreEmpty { showsOnlyDrafts = false }
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
                    deleteButton(for: garment)
                }
                .modifier(LibraryCardJiggle(id: garment.id))
                .accessibilityElement(children: .contain)
        } else {
            NavigationLink(value: garment.id) {
                ProductLibraryCard(garment: garment)
            }
            .buttonStyle(.plain)
            .modifier(LibraryCardEditGesture(onEdit: { setEditing(true) }))
            .accessibilityIdentifier("library.product.\(garment.id.uuidString)")
        }
    }

    @ViewBuilder
    private func draftCell(_ garment: Garment) -> some View {
        if let draft = garment.creationDraft {
            Button {
                isSearchFocused = false
                onResumeDraft(garment.id)
            } label: {
                ProductLibraryDraftCard(garment: garment, draft: draft)
            }
            .buttonStyle(.plain)
            .modifier(LibraryCardEditGesture(onEdit: { setEditing(true, selectingDrafts: true) }))
            .accessibilityIdentifier("library.draft.\(garment.id.uuidString)")
            .accessibilityHint("저장한 \(draft.step.title)부터 작업을 이어갑니다. 길게 누르면 보관함을 수정합니다.")
        }
    }

    @ViewBuilder
    private func draftProductCell(_ garment: Garment) -> some View {
        if isEditing {
            ProductLibraryCard(garment: garment, showsDraftPlaceholders: true)
                .overlay(alignment: .topLeading) {
                    deleteButton(for: garment)
                }
                .modifier(LibraryCardJiggle(id: garment.id))
                .accessibilityElement(children: .contain)
        } else {
            Button {
                isSearchFocused = false
                onResumeDraft(garment.id)
            } label: {
                ProductLibraryCard(garment: garment, showsDraftPlaceholders: true)
            }
            .buttonStyle(.plain)
            .modifier(LibraryCardEditGesture(onEdit: { setEditing(true, selectingDrafts: true) }))
            .accessibilityIdentifier("library.draft.\(garment.id.uuidString)")
            .accessibilityHint("임시저장한 상품 작업을 이어갑니다.")
        }
    }

    private func setEditing(_ editing: Bool, selectingDrafts: Bool = false) {
        isSearchFocused = false
        withAnimation(.easeInOut(duration: 0.18)) {
            if editing && (selectingDrafts || filteredSavedGarments.isEmpty) && !draftGarments.isEmpty {
                showsOnlyDrafts = true
            }
            isEditing = editing
        }
    }

    private func deleteButton(for garment: Garment) -> some View {
        Button(role: .destructive) {
            pendingDeletion = garment.id
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(LibraryStyle.primary)
                .frame(width: 25, height: 25, alignment: .center)
                .background {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [Color(white: 0.93).opacity(0.92), .white.opacity(0.96)],
                                    startPoint: .top, endPoint: .bottom
                                ))
                        }
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.02), radius: 8.46, y: 4.51)
                }
                .compositingGroup()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: -17.5, y: -19.5)
        .accessibilityLabel("\(garment.name.isEmpty ? "상품" : garment.name) 삭제")
        .accessibilityIdentifier("library.delete.\(garment.id.uuidString)")
    }

    private func deleteProduct(id: UUID) {
        pendingDeletion = nil
        do {
            try GarmentStore.deleteSavedGarment(id: id, in: context.container)
        } catch {
            deletionFailed = true
        }
    }

}

/// A successful hold consumes the touch so it cannot also open the product or draft.
private struct LibraryCardEditGesture: ViewModifier {
    let onEdit: () -> Void

    func body(content: Content) -> some View {
        content
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                    .onEnded { _ in onEdit() }
            )
            .accessibilityAction(named: Text("보관함 수정"), onEdit)
            .accessibilityHint("길게 누르면 삭제할 수 있는 수정 모드로 전환합니다.")
    }
}

/// Continuous rotation and sub-point movement, with a slightly different rhythm per card.
private struct LibraryCardJiggle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let id: UUID

    private var direction: Double { id.uuid.0.isMultiple(of: 2) ? 1 : -1 }
    // A slightly calmer rhythm than the reference Home Screen recording.
    private var duration: Double { 0.30 + Double(id.uuid.1 % 5) * 0.00625 }
    private var rotation: Double { 1.0 * direction }

    func body(content: Content) -> some View {
        if reduceMotion || scenePhase != .active {
            content
        } else {
            content.keyframeAnimator(initialValue: LibraryCardMotion(
                rotation: -rotation, x: -0.4 * direction, y: -0.4
            )) { card, motion in
                card
                    .rotationEffect(.degrees(motion.rotation))
                    .offset(x: motion.x, y: motion.y)
            } keyframes: { _ in
                KeyframeTrack(\.rotation) {
                    LinearKeyframe(rotation, duration: duration / 2)
                    LinearKeyframe(-rotation, duration: duration / 2)
                }
                KeyframeTrack(\.x) {
                    LinearKeyframe(0.4 * direction, duration: duration / 4)
                    LinearKeyframe(-0.4 * direction, duration: duration / 4)
                    LinearKeyframe(0.4 * direction, duration: duration / 4)
                    LinearKeyframe(-0.4 * direction, duration: duration / 4)
                }
                KeyframeTrack(\.y) {
                    LinearKeyframe(0.4, duration: duration / 4)
                    LinearKeyframe(0.4, duration: duration / 4)
                    LinearKeyframe(-0.4, duration: duration / 4)
                    LinearKeyframe(-0.4, duration: duration / 4)
                }
            }
        }
    }
}

private struct LibraryCardMotion {
    var rotation: Double
    var x: Double
    var y: Double
}

#if DEBUG
private struct ProductLibraryPreview: View {
    @Query(sort: \Garment.updatedAt, order: .reverse) private var garments: [Garment]
    @State var isEditing = false
    var initiallyShowsOnlyDrafts = false

    var body: some View {
        NavigationStack {
            ProductLibraryView(
                garments: garments,
                isEditing: $isEditing,
                onStartMeasurement: {},
                initiallyShowsOnlyDrafts: initiallyShowsOnlyDrafts
            )
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

#Preview("보관함 · 임시저장") {
    ProductLibraryPreview()
        .modelContainer(LibraryPreviewData.makeContainer(includesDraft: true))
        .tint(LibraryStyle.primary)
        .preferredColorScheme(.light)
}

#Preview("보관함 · 임시저장 필터") {
    ProductLibraryPreview(initiallyShowsOnlyDrafts: true)
        .modelContainer(LibraryPreviewData.makeContainer(includesDraft: true))
        .tint(LibraryStyle.primary)
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
