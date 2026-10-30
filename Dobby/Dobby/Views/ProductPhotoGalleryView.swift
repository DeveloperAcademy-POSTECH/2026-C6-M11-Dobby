import SwiftUI
import UIKit

struct ProductPhotoGalleryView: View {
    @State private var photos: [GarmentPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int
    @State private var isPaging = false
    @State private var showsDeletionError = false
    private let onDelete: ((UUID) throws -> Bool)?

    private let controlBackground = Color.black.opacity(0.3)

    init(photos: [GarmentPhoto], initialPhotoID: UUID,
         onDelete: ((UUID) throws -> Bool)? = nil) {
        _photos = State(initialValue: photos)
        _selectedIndex = State(initialValue: photos.firstIndex { $0.id == initialPhotoID } ?? 0)
        self.onDelete = onDelete
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
            ProductPhotoPager(photos: photos, selectedIndex: $selectedIndex,
                              onTransitionChange: { isPaging = $0 })
            .id(photos.map(\.id))
            .frame(width: geometry.size.width, height: photoHeight)
            .clipped()
            .accessibilityIdentifier("product-gallery.pager")
            .accessibilityValue("\(selectedIndex + 1) / \(photos.count)")
            .background(.black)
            .overlay(alignment: .topLeading) {
                Button("닫기", systemImage: "chevron.left", action: close)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(controlBackground, in: Circle())
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("product-gallery.close")
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                if onDelete != nil {
                    Button("제품 사진 삭제", systemImage: "trash.fill", role: .destructive,
                           action: deleteCurrentPhoto)
                        .labelStyle(.iconOnly)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.2), in: Circle())
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        .disabled(photos.isEmpty || isPaging)
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
                        .background {
                            Capsule().fill(controlBackground).frame(height: 26)
                        }
                        .scaleEffect(0.85)
                        .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color.black.opacity(0.8)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let photoTop = (geometry.size.height - photoHeight) / 2
                        if location.y < photoTop || location.y > photoTop + photoHeight {
                            close()
                        }
                    }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.light)
        .alert("사진을 삭제하지 못했어요", isPresented: $showsDeletionError) {
            Button("확인", role: .cancel) { }
        } message: {
            Text("사진은 그대로 남아 있어요. 다시 시도해 주세요.")
        }
    }

    private func deleteCurrentPhoto() {
        guard !isPaging, let onDelete, photos.indices.contains(selectedIndex) else { return }
        let photoID = photos[selectedIndex].id
        do {
            guard try onDelete(photoID) else { return }
            photos.removeAll { $0.id == photoID }
            selectedIndex = min(selectedIndex, max(0, photos.count - 1))
            if photos.isEmpty { close() }
        } catch {
            showsDeletionError = true
        }
    }

    private func close() {
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
        control.pageIndicatorTintColor = .white.withAlphaComponent(0.4)
        control.currentPageIndicatorTintColor = .white
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
