import SwiftUI
import UIKit

enum ProductPhotoRemovalBadgeLayout {
    static let diameter: CGFloat = 17
    static let topOverflow: CGFloat = 3
    static let trailingOverflow: CGFloat = 4
}

/// Local-only native photo dragging. Model order changes only on a completed drop.
struct ProductPhotoReorderStrip<Content: View>: UIViewRepresentable {
    let photos: [GarmentPhoto]
    let spacing: CGFloat
    let topInset: CGFloat
    let onReorder: ([UUID]) -> Bool
    var includesRemovalButton = false
    var leadingContent: AnyView? = nil

    private var previewInsets: UIEdgeInsets {
        includesRemovalButton
            ? .init(top: ProductPhotoRemovalBadgeLayout.topOverflow, left: 0, bottom: 0,
                    right: ProductPhotoRemovalBadgeLayout.trailingOverflow)
            : .zero
    }

    private func configure(_ layout: UICollectionViewFlowLayout) {
        let size = ProductDetailPhotoPresentation.compact.size
        let insets = previewInsets
        // Reserve the badge overhang inside the native cell snapshot, while
        // keeping the visible photo size, spacing and position unchanged.
        layout.itemSize = CGSize(width: size.width + insets.right, height: size.height + insets.top)
        layout.minimumLineSpacing = spacing - insets.right
        layout.sectionInset = .init(top: max(0, topInset - insets.top), left: 20, bottom: 0,
                                    right: 20 - insets.right)
    }

    private func hosted(_ view: AnyView) -> some View {
        view.padding(.top, previewInsets.top).padding(.trailing, previewInsets.right)
    }
    @ViewBuilder let content: (GarmentPhoto) -> Content
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        configure(layout)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        // Lifted cells and their overhanging removal badges must not be cut
        // against the strip's rectangular viewport during reordering.
        view.clipsToBounds = false
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.contentInsetAdjustmentBehavior = .never
        view.isAccessibilityElement = false
        view.shouldGroupAccessibilityChildren = true
        view.accessibilityLabel = "제품 사진 목록"
        view.dataSource = context.coordinator
        view.dragDelegate = context.coordinator
        view.dropDelegate = context.coordinator
        view.dragInteractionEnabled = true
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "photo")
        context.coordinator.collectionView = view
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(parent: self, isEnabled: isEnabled)
        if let layout = view.collectionViewLayout as? UICollectionViewFlowLayout {
            configure(layout)
        }
        view.isUserInteractionEnabled = isEnabled
        view.dragInteractionEnabled = isEnabled && photos.count > 1
        view.accessibilityElementsHidden = !isEnabled
    }

    static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
        coordinator.isActive = false
        view.dataSource = nil
        view.dragDelegate = nil
        view.dropDelegate = nil
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        weak var collectionView: UICollectionView?
        var isActive = true
        private var parent: ProductPhotoReorderStrip
        private var photos: [GarmentPhoto]
        private var photoURLs: [UUID: URL]
        private var isEnabled = true
        private let feedback = UIImpactFeedbackGenerator(style: .light)
        private var activeDragID: UUID?

        init(parent: ProductPhotoReorderStrip) {
            self.parent = parent
            self.photos = parent.photos
            self.photoURLs = Dictionary(uniqueKeysWithValues: parent.photos.map { ($0.id, GarmentStore.url(for: $0)) })
        }

        fileprivate func update(parent: ProductPhotoReorderStrip, isEnabled: Bool) {
            self.parent = parent
            self.isEnabled = isEnabled
            let updatedURLs = Dictionary(uniqueKeysWithValues: parent.photos.map { ($0.id, GarmentStore.url(for: $0)) })
            if photos.map(\.id) != parent.photos.map(\.id) || photoURLs != updatedURLs {
                activeDragID = nil
                photos = parent.photos
                photoURLs = updatedURLs
                collectionView?.reloadData()
            }
            if let leading = parent.leadingContent,
               let cell = collectionView?.cellForItem(at: IndexPath(item: 0, section: 0)) {
                cell.contentConfiguration = UIHostingConfiguration { parent.hosted(leading) }.margins(.all, 0)
            }
            if !isEnabled { activeDragID = nil }
        }

        private var photoOffset: Int { parent.leadingContent == nil ? 0 : 1 }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { photos.count + photoOffset }

        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath)
            // Hosted photo/add/remove buttons retain their own actions and IDs.
            // Making the collection cell a separate element would hide them.
            cell.isAccessibilityElement = false
            cell.shouldGroupAccessibilityChildren = true
            if indexPath.item == 0, let leading = parent.leadingContent {
                cell.contentConfiguration = UIHostingConfiguration { parent.hosted(leading) }.margins(.all, 0)
                cell.backgroundConfiguration = .clear()
                return cell
            }
            let photoIndex = indexPath.item - photoOffset
            guard photos.indices.contains(photoIndex) else { return cell }
            let photo = photos[photoIndex]
            cell.contentConfiguration = UIHostingConfiguration { parent.hosted(AnyView(parent.content(photo))) }.margins(.all, 0)
            cell.backgroundConfiguration = .clear()
            cell.clipsToBounds = false
            cell.contentView.clipsToBounds = false
            return cell
        }

        func collectionView(_ view: UICollectionView, itemsForBeginning session: any UIDragSession,
                            at indexPath: IndexPath) -> [UIDragItem] {
            let photoIndex = indexPath.item - photoOffset
            guard isActive, isEnabled, photos.count > 1, photos.indices.contains(photoIndex) else { return [] }
            let id = photos[photoIndex].id
            let item = UIDragItem(itemProvider: NSItemProvider(object: id.uuidString as NSString))
            item.localObject = id
            // Let UIKit lift the complete hosted photo and badge together.
            // Both now fit inside the cell's snapshot bounds.
            session.localContext = self
            activeDragID = id
            feedback.prepare()
            return [item]
        }

        func collectionView(_ view: UICollectionView,
                            dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            photoPreviewParameters(in: view, at: indexPath)
        }

        func collectionView(_ view: UICollectionView,
                            dropPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
            photoPreviewParameters(in: view, at: indexPath)
        }

        private func photoPreviewParameters(in view: UICollectionView, at indexPath: IndexPath) -> UIDragPreviewParameters? {
            guard photos.indices.contains(indexPath.item - photoOffset),
                  let cell = view.cellForItem(at: indexPath) else { return nil }
            let size = ProductDetailPhotoPresentation.compact.size
            let photoRect = CGRect(origin: CGPoint(x: 0, y: parent.previewInsets.top), size: size)
            let path = UIBezierPath(roundedRect: photoRect, cornerRadius: 16)
            if parent.includesRemovalButton {
                let diameter = ProductPhotoRemovalBadgeLayout.diameter
                path.append(UIBezierPath(ovalIn: CGRect(x: cell.contentView.bounds.maxX - diameter,
                                                       y: 0, width: diameter, height: diameter)))
            }
            let parameters = UIDragPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = path
            return parameters
        }

        func collectionView(_ view: UICollectionView, dragSessionWillBegin session: any UIDragSession) {
            if activeDragID != nil { feedback.impactOccurred() }
        }

        func collectionView(_ view: UICollectionView, dragSessionDidEnd session: any UIDragSession) {
            activeDragID = nil
        }

        func collectionView(_ view: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: any UIDragSession) -> Bool { true }

        func collectionView(_ view: UICollectionView, canHandle session: any UIDropSession) -> Bool {
            isActive && isEnabled && (session.localDragSession?.localContext as? Coordinator) === self
        }

        func collectionView(_ view: UICollectionView, dropSessionDidUpdate session: any UIDropSession,
                            withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
            guard isActive, isEnabled, UIApplication.shared.applicationState == .active,
                  activeDragID != nil, (session.localDragSession?.localContext as? Coordinator) === self else {
                return .init(operation: .cancel)
            }
            return .init(operation: .move, intent: .insertAtDestinationIndexPath)
        }

        func collectionView(_ view: UICollectionView, performDropWith coordinator: any UICollectionViewDropCoordinator) {
            guard isActive, isEnabled, UIApplication.shared.applicationState == .active,
                  (coordinator.session.localDragSession?.localContext as? Coordinator) === self,
                  let item = coordinator.items.first,
                  let id = item.dragItem.localObject as? UUID, id == activeDragID,
                  let source = photos.firstIndex(where: { $0.id == id }), !photos.isEmpty else { return }
            let destination = min(photos.count - 1, max(0, (coordinator.destinationIndexPath?.item).map { $0 - photoOffset } ?? photos.count - 1))
            guard source != destination else {
                coordinator.drop(item.dragItem, toItemAt: IndexPath(item: source + photoOffset, section: 0))
                return
            }
            var reordered = photos
            reordered.insert(reordered.remove(at: source), at: destination)
            guard parent.onReorder(reordered.map(\.id)) else { return }
            photos = reordered
            view.performBatchUpdates {
                view.moveItem(at: IndexPath(item: source + photoOffset, section: 0), to: IndexPath(item: destination + photoOffset, section: 0))
            }
            coordinator.drop(item.dragItem, toItemAt: IndexPath(item: destination + photoOffset, section: 0))
        }
    }
}
