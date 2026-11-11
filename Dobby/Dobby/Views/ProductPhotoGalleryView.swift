import SwiftUI
import UIKit

struct ProductPhotoGalleryView: View {
    @State private var photos: [GarmentPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var isPaging = false
    @State private var isRotating = false
    @State private var rotationError: String?
    @State private var showsDeletionError = false
    @State private var pendingDeletionID: UUID?
    @State private var dismissalOffset: CGFloat = 0
    @State private var isClosing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onRotate: ((UUID) async throws -> Bool)?
    private let onDelete: ((UUID) throws -> Bool)?

    private let controlBackground = Color.black.opacity(0.2)
    private let controlFont = Font.system(size: 17, weight: .semibold)

    init(photos: [GarmentPhoto], initialPhotoID: UUID,
         onDelete: ((UUID) throws -> Bool)? = nil,
         onRotate: ((UUID) async throws -> Bool)? = nil) {
        _photos = State(initialValue: photos)
        _selectedIndex = State(initialValue: photos.firstIndex { $0.id == initialPhotoID } ?? 0)
        self.onDelete = onDelete
        self.onRotate = onRotate
    }

    private var pageSelection: Binding<Int> {
        Binding(get: { selectedIndex }, set: { index in
            guard photos.indices.contains(index), index != selectedIndex else { return }
            isPaging = true
            withAnimation { selectedIndex = index }
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let photoHeight = min(geometry.size.width * 4 / 3, geometry.size.height)
            let dragProgress = min(1, dismissalOffset / max(1, geometry.size.height * 0.6))
            ZStack {
                Color.black.opacity(0.8 * (1 - dragProgress))
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard pendingDeletionID == nil, !isClosing else { return }
                        let photoTop = (geometry.size.height - photoHeight) / 2
                        if location.y < photoTop || location.y > photoTop + photoHeight { close() }
                    }

                photoSurface(in: geometry.size, height: photoHeight)
                    .scaleEffect(1 - dragProgress * 0.12)
                    .offset(y: dismissalOffset)
                    .allowsHitTesting(pendingDeletionID == nil && !isClosing && !isRotating)
                    .accessibilityHidden(pendingDeletionID != nil)

                if pendingDeletionID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pendingDeletionID = nil }
                        .accessibilityHidden(true)

                    ProductPhotoDeletionConfirmation(onDelete: confirmDeletion,
                                                     onCancel: { pendingDeletionID = nil })
                        .padding(.horizontal, 10)
                        .padding(.top, max(0, (geometry.size.height - photoHeight) / 2) + 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onChange(of: geometry.size) { _, _ in resetDismissal() }
            .onChange(of: selectedIndex) { _, _ in
                pendingDeletionID = nil
                resetDismissal()
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .accessibilityAction(.escape) {
            if pendingDeletionID != nil { pendingDeletionID = nil } else { close() }
        }
        .onDisappear { isClosing = false }
        .alert("사진을 회전하지 못했어요", isPresented: Binding(
            get: { rotationError != nil }, set: { if !$0 { rotationError = nil } })) {
            Button("확인", role: .cancel) { rotationError = nil }
        } message: { Text(rotationError ?? "사진은 그대로 남아 있어요. 다시 시도해 주세요.") }
        .alert("사진을 삭제하지 못했어요", isPresented: $showsDeletionError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("사진은 그대로 남아 있어요. 다시 시도해 주세요.")
        }
    }

    private func photoSurface(in size: CGSize, height: CGFloat) -> some View {
        ProductPhotoPager(photos: photos, selectedIndex: $selectedIndex,
                          onTransitionChange: { isPaging = $0 },
                          allowsDismissGesture: pendingDeletionID == nil && !showsDeletionError && !isClosing && !isRotating,
                          onDismissDragChanged: updateDismissal,
                          onDismissDragEnded: { distance, velocity, cancelled in
                              endDismissal(distance: distance, velocity: velocity, cancelled: cancelled,
                                           containerHeight: size.height)
                          })
        .id(photos.map { "\($0.id)-\($0.productRotationQuarterTurns ?? 0)" })
        .frame(width: size.width, height: height)
        .clipped()
        .accessibilityIdentifier("product-gallery.pager")
        .accessibilityValue("\(photos.isEmpty ? 0 : selectedIndex + 1) / \(photos.count)")
        .background(.black)
        .overlay(alignment: .topLeading) {
            Button("닫기", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(controlFont)
                .foregroundStyle(.black)
                .frame(width: 48, height: 48)
                .glassEffect(.regular, in: Circle())
                .contentShape(Circle())
                .buttonStyle(.plain)
                .accessibilityIdentifier("product-gallery.close")
                .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if onRotate != nil {
                Button("사진 회전", systemImage: "rotate.right") { Task { await rotateSelectedPhoto() } }
                    .labelStyle(.iconOnly)
                    .font(controlFont)
                    .foregroundStyle(.black)
                    .frame(width: 56, height: 48)
                    .glassEffect(.regular, in: Capsule())
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                    .disabled(photos.isEmpty || isPaging || isRotating || dismissalOffset > 0)
                    .accessibilityIdentifier("product-gallery.rotate")
                    .padding(10)
            } else if onDelete != nil {
                Button("제품 사진 삭제", systemImage: "trash", action: requestDeletion)
                    .labelStyle(.iconOnly)
                    .font(controlFont)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(controlBackground, in: Circle())
                    .contentShape(Circle())
                    .buttonStyle(.plain)
                    .disabled(photos.isEmpty || isPaging || dismissalOffset > 0)
                    .accessibilityIdentifier("product-gallery.delete")
                    .padding(10)
            }
        }
        .overlay(alignment: .bottom) {
            if photos.count > 1 {
                ProductPhotoPageControl(count: photos.count, selection: pageSelection)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .background { Capsule().fill(.ultraThinMaterial).frame(height: 24) }
                    .padding(.bottom, 20)
                    .disabled(isClosing || dismissalOffset > 0)
            }
        }
    }

    private func rotateSelectedPhoto() async {
        guard !isPaging, !isClosing, !isRotating, dismissalOffset == 0,
              let onRotate, photos.indices.contains(selectedIndex) else { return }
        let identifier = photos[selectedIndex].id
        isRotating = true
        defer { isRotating = false }
        do {
            guard try await onRotate(identifier) else {
                rotationError = "이 사진을 찾을 수 없어요. 화면을 다시 열어 주세요."
                return
            }
        } catch {
            rotationError = "사진은 그대로 남아 있어요. 다시 시도해 주세요."
        }
    }

    private func requestDeletion() {
        guard !isPaging, !isClosing, onDelete != nil, photos.indices.contains(selectedIndex) else { return }
        pendingDeletionID = photos[selectedIndex].id
    }

    private func confirmDeletion() {
        guard !isPaging, let onDelete, let photoID = pendingDeletionID else { return }
        pendingDeletionID = nil
        do {
            guard try onDelete(photoID) else { showsDeletionError = true; return }
            photos.removeAll { $0.id == photoID }
            selectedIndex = min(selectedIndex, max(0, photos.count - 1))
            isPaging = false
            if photos.isEmpty { close() }
        } catch {
            showsDeletionError = true
        }
    }

    private func updateDismissal(_ distance: CGFloat) {
        guard pendingDeletionID == nil, !isClosing else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismissalOffset = max(0, distance) }
    }

    private func endDismissal(distance: CGFloat, velocity: CGFloat, cancelled: Bool,
                              containerHeight: CGFloat) {
        guard !isClosing else { return }
        let crossedThreshold = distance >= min(140, containerHeight * 0.22)
        let fastSwipe = distance > 30 && velocity > 900
        guard !cancelled, pendingDeletionID == nil, crossedThreshold || fastSwipe else {
            resetDismissal()
            return
        }
        if reduceMotion { close(); return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            dismissalOffset = max(distance, containerHeight)
        } completion: {
            guard isClosing else { return }
            dismissImmediately()
        }
    }

    private func resetDismissal() {
        guard !isClosing else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
            dismissalOffset = 0
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        dismissImmediately()
    }

    private func dismissImmediately() {
        pendingDeletionID = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
    }
}

private struct ProductPhotoPageControl: UIViewRepresentable {
    let count: Int
    @Binding var selection: Int

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.backgroundStyle = .minimal
        control.pageIndicatorTintColor = .tertiaryLabel
        control.currentPageIndicatorTintColor = .label
        control.overrideUserInterfaceStyle = .light
        control.accessibilityLabel = "제품 사진 페이지"
        control.accessibilityIdentifier = "product-gallery.page-control"
        control.addTarget(context.coordinator, action: #selector(Coordinator.changePage(_:)),
                          for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.selection = $selection
        control.numberOfPages = count
        control.currentPage = selection
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPageControl, context: Context) -> CGSize? {
        CGSize(width: uiView.size(forNumberOfPages: count).width, height: 44)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) {
            self.selection = selection
        }

        @objc func changePage(_ control: UIPageControl) {
            selection.wrappedValue = control.currentPage
        }
    }
}
