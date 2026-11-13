import SwiftUI
import UIKit

enum ProductPhotoGalleryStyle {
    case standard
    case library
    case editing

    var rotationGlass: Glass {
        self == .editing ? .regular.tint(.gray.opacity(0.32)) : .regular
    }
}

struct ProductPhotoGalleryView: View {
    @State private var photos: [GarmentPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var isPaging = false
    @State private var isRotating = false
    @State private var isRotationAnimating = false
    @State private var rotationTask: Task<Void, Never>?
    @State private var rotationOperationID: UUID?
    @State private var rotationError: String?
    @State private var showsDeletionError = false
    @State private var pendingDeletionID: UUID?
    @State private var dismissalOffset: CGFloat = 0
    @State private var isClosing = false
    @State private var originalImageSizes: [URL: CGSize] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onRotate: ((UUID) async throws -> Bool)?
    private let onDelete: ((UUID) throws -> Bool)?
    private let style: ProductPhotoGalleryStyle
    @State private var controlReferenceURL: URL?
    @State private var controlReferenceTurns: Int

    private let controlBackground = Color.black.opacity(0.2)
    private let controlFont = Font.system(size: 17, weight: .semibold)

    private var rotationIsBusy: Bool { isRotating || isRotationAnimating }

    private var rotationDescription: String {
        guard photos.indices.contains(selectedIndex) else { return "" }
        let turns = ((photos[selectedIndex].productRotationQuarterTurns ?? 0) % 4 + 4) % 4
        return rotationIsBusy ? "회전 중" : "왼쪽으로 \((4 - turns) % 4 * 90)도 회전"
    }

    init(photos: [GarmentPhoto], initialPhotoID: UUID,
         style: ProductPhotoGalleryStyle = .standard,
         onDelete: ((UUID) throws -> Bool)? = nil,
         onRotate: ((UUID) async throws -> Bool)? = nil) {
        _photos = State(initialValue: photos)
        _selectedIndex = State(initialValue: photos.firstIndex { $0.id == initialPhotoID } ?? 0)
        self.onDelete = onDelete
        self.onRotate = onRotate
        self.style = style
        let reference = photos.first(where: { $0.id == initialPhotoID }) ?? photos.first
        _controlReferenceURL = State(initialValue: reference.map { GarmentStore.photosDirectory.appending(path: $0.fileName) })
        _controlReferenceTurns = State(initialValue:
            ProductPhotoRotationLayout.normalizedQuarterTurns(reference?.productRotationQuarterTurns ?? 0))
    }

    private var pageSelection: Binding<Int> {
        Binding(get: { selectedIndex }, set: { index in
            guard !rotationIsBusy, photos.indices.contains(index), index != selectedIndex else { return }
            isPaging = true
            withAnimation { selectedIndex = index }
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let photoSize = displayedPhotoSize(in: geometry.size)
            let photoRect = CGRect(x: (geometry.size.width - photoSize.width) / 2,
                                   y: (geometry.size.height - photoSize.height) / 2,
                                   width: photoSize.width, height: photoSize.height)
            let dragProgress = min(1, dismissalOffset / max(1, geometry.size.height * 0.6))
            ZStack {
                Color.black.opacity(0.8 * (1 - dragProgress))
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard pendingDeletionID == nil, !isClosing else { return }
                        if !photoRect.contains(location) { close() }
                    }

                photoSurface(in: geometry.size,
                    height: min(geometry.size.width * (style == .editing ? 561.0 / 402.0 : 4.0 / 3.0), geometry.size.height))
                    .scaleEffect(1 - dragProgress * 0.12)
                    .offset(y: dismissalOffset)
                    .allowsHitTesting(pendingDeletionID == nil && !isClosing && !rotationIsBusy)
                    .accessibilityHidden(pendingDeletionID != nil)

                if pendingDeletionID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { pendingDeletionID = nil }
                        .accessibilityHidden(true)

                    ProductPhotoDeletionConfirmation(onDelete: confirmDeletion,
                                                     onCancel: { pendingDeletionID = nil })
                        .padding(.horizontal, photoRect.minX + 10)
                        .padding(.top, photoRect.minY + 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onChange(of: geometry.size) { _, _ in resetDismissal() }
            .onChange(of: selectedIndex) { _, _ in
                pendingDeletionID = nil
                resetDismissal()
            }
            .onChange(of: photos.map(\.id)) { _, _ in cancelRotation() }
        }
        .task(id: style == .editing ? photos.map(\.fileName) : []) {
            guard style == .editing else { return }
            let urls = photos.map { GarmentStore.photosDirectory.appending(path: $0.fileName) }
            let sizes = await Task.detached(priority: .userInitiated) {
                var result: [URL: CGSize] = [:]
                for url in urls {
                    guard !Task.isCancelled else { break }
                    guard let metadata = try? ProductPhotoHandoff.metadata(for: url) else {
                        result[url] = .zero
                        continue
                    }
                    switch metadata.orientation {
                    case .left, .leftMirrored, .right, .rightMirrored:
                        result[url] = CGSize(width: metadata.pixelHeight, height: metadata.pixelWidth)
                    default:
                        result[url] = CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
                    }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            originalImageSizes.merge(sizes) { _, new in new }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .accessibilityAction(.escape) {
            if pendingDeletionID != nil { pendingDeletionID = nil } else { close() }
        }
        .onDisappear {
            cancelRotation()
            isClosing = false
        }
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

    private var selectedOriginalURL: URL? {
        guard photos.indices.contains(selectedIndex) else { return nil }
        return GarmentStore.photosDirectory.appending(path: photos[selectedIndex].fileName)
    }

    private var hasResolvedControlSize: Bool {
        style != .editing || controlReferenceURL == nil || controlReferenceURL.flatMap { originalImageSizes[$0] } != nil
    }

    /// Establish the controls from the photo used to open the viewer, then keep
    /// that area unchanged while paging and rotating. Only screen resizing reflows it.
    private func controlAreaSize(in available: CGSize) -> CGSize {
        let maximum = CGSize(width: available.width,
            height: min(available.width * (style == .editing ? 561.0 / 402.0 : 4.0 / 3.0), available.height))
        guard style == .editing, let url = controlReferenceURL, let original = originalImageSizes[url],
              original.width > 0, original.height > 0 else { return maximum }
        let oriented = ProductPhotoRotationLayout.rotatedBounds(imageSize: original, angleDegrees: Double(controlReferenceTurns) * 90)
        return ProductPhotoRotationLayout.fittedImageSize(imageSize: oriented, containerSize: maximum, angleDegrees: 0)
    }

    private func displayedPhotoSize(in available: CGSize) -> CGSize {
        let maximum = CGSize(width: available.width,
            height: min(available.width * (style == .editing ? 561.0 / 402.0 : 4.0 / 3.0), available.height))
        guard style == .editing, let url = selectedOriginalURL, let original = originalImageSizes[url],
              original.width > 0, original.height > 0, photos.indices.contains(selectedIndex) else { return maximum }
        let turns = ProductPhotoRotationLayout.normalizedQuarterTurns(photos[selectedIndex].productRotationQuarterTurns ?? 0)
        let oriented = ProductPhotoRotationLayout.rotatedBounds(imageSize: original, angleDegrees: Double(turns) * 90)
        return ProductPhotoRotationLayout.fittedImageSize(imageSize: oriented, containerSize: maximum, angleDegrees: 0)
    }

    private func photoSurface(in size: CGSize, height: CGFloat) -> some View {
        ProductPhotoPager(photos: photos, selectedIndex: $selectedIndex,
                          onTransitionChange: { isPaging = $0 },
                          onRotationAnimationChange: { isRotationAnimating = $0 },
                          allowsDismissGesture: pendingDeletionID == nil && !showsDeletionError && !isClosing && !rotationIsBusy,
                          allowsPaging: !rotationIsBusy,
                          onDismissDragChanged: updateDismissal,
                          onDismissDragEnded: { distance, velocity, cancelled in
                              endDismissal(distance: distance, velocity: velocity, cancelled: cancelled,
                                           containerHeight: size.height)
                          })
        .id(photos.map(\.id))
        .frame(width: size.width, height: height)
        .clipped()
        .accessibilityIdentifier("product-gallery.pager")
        .accessibilityValue("\(photos.isEmpty ? 0 : selectedIndex + 1) / \(photos.count)")
        .overlay {
            let controlsSize = controlAreaSize(in: CGSize(width: size.width, height: height))
            photoControls(in: controlsSize)
                .opacity(hasResolvedControlSize ? 1 : 0)
                .allowsHitTesting(hasResolvedControlSize)
        }
    }

    private func photoControls(in size: CGSize) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            closeControl
                .accessibilityIdentifier("product-gallery.close")
                .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            if onRotate != nil {
                rotationControl
                    .disabled(photos.isEmpty || isPaging || rotationIsBusy || dismissalOffset > 0)
                    .accessibilityLabel("사진 회전")
                    .accessibilityValue(rotationDescription)
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
                Group {
                    if style != .standard {
                        ProductPhotoPageIndicator(count: photos.count, selection: pageSelection)
                    } else {
                        ProductPhotoPageControl(count: photos.count, selection: pageSelection)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 44)
                            .padding(.horizontal, 10)
                            .background { Capsule().fill(.ultraThinMaterial).frame(height: 24) }
                    }
                }
                    .padding(.bottom, 20)
                    .disabled(isClosing || dismissalOffset > 0 || rotationIsBusy)
            }
        }
    }

    @ViewBuilder
    private var closeControl: some View {
        if style == .library {
            closeButton.background(controlBackground, in: Circle())
        } else {
            closeButton.glassEffect(.regular, in: Circle())
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: style == .library ? "chevron.backward" : "xmark")
                .font(controlFont)
                .imageScale(style == .standard ? .medium : .large)
                .offset(x: style == .library ? -1 : 0, y: style == .library ? -0.5 : 0)
        }
            .accessibilityLabel(style == .library ? "뒤로가기" : "닫기")
            .foregroundStyle(style == .library ? Color.white : Color.black)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .buttonStyle(.plain)
    }

    private var rotationControl: some View {
        Button(action: rotateSelectedPhoto) {
            Group {
                if style == .editing {
                    Image(systemName: "rotate.left")
                        .font(controlFont)
                        .imageScale(.large)
                        .offset(y: -2) // Align the symbol ink with Figma's 36pt symbol slot.
                } else {
                    Image("ProductPhotoRotateLeft").renderingMode(.template)
                }
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
        }
        .foregroundStyle(.black)
        .frame(width: style == .editing ? 48 : 56, height: style == .editing ? 48 : 56)
        .glassEffect(style.rotationGlass, in: Circle())
        .contentShape(Circle())
        .buttonStyle(.plain)
    }

    private func rotateSelectedPhoto() {
        guard !isPaging, !isClosing, !rotationIsBusy, dismissalOffset == 0,
              let onRotate, photos.indices.contains(selectedIndex) else { return }
        let identifier = photos[selectedIndex].id
        let operationID = UUID()
        rotationOperationID = operationID
        isRotating = true
        rotationTask = Task { @MainActor in
            defer {
                if rotationOperationID == operationID {
                    isRotating = false
                    rotationTask = nil
                    rotationOperationID = nil
                }
            }
            do {
                guard try await onRotate(identifier) else {
                    try Task.checkCancellation()
                    rotationError = "이 사진을 찾을 수 없어요. 화면을 다시 열어 주세요."
                    return
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                // Closing the viewer cancels outstanding work without an alert.
            } catch {
                guard !Task.isCancelled else { return }
                rotationError = "사진은 그대로 남아 있어요. 다시 시도해 주세요."
            }
        }
    }

    private func cancelRotation() {
        rotationTask?.cancel()
        rotationTask = nil
        rotationOperationID = nil
        isRotating = false
        isRotationAnimating = false
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
        rotationTask?.cancel()
        pendingDeletionID = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { dismiss() }
    }
}

/// UIPageControl does not expose dot spacing. The designed galleries use
/// Figma's 8pt dots/8pt gaps, retaining a 44pt tap and VoiceOver-adjustable area.
private struct ProductPhotoPageIndicator: View {
    let count: Int
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == selection ? Color.black : Color(uiColor: .tertiaryLabel))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial).opacity(0.06)
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(.white.opacity(0.03)).blendMode(.colorDodge)
            }
            .frame(height: 24)
        }
        .offset(x: -1) // Figma's page-control capsule is optically offset by 1pt.
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            selection = min(count - 1, max(0, Int((value.location.x - 8) / 16)))
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("제품 사진 페이지")
        .accessibilityValue("\(selection + 1) / \(count)")
        .accessibilityIdentifier("product-gallery.page-control")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selection = min(count - 1, selection + 1)
            case .decrement: selection = max(0, selection - 1)
            @unknown default: break
            }
        }
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
