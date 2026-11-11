import SwiftUI
import UIKit

/// Local-only native photo dragging. Model order changes only on a completed drop.
struct ProductPhotoReorderStrip<Content: View>: UIViewRepresentable {
    let photos: [GarmentPhoto]
    let spacing: CGFloat
    let topInset: CGFloat
    let onReorder: ([UUID]) -> Bool
    var leadingContent: AnyView? = nil
    @ViewBuilder let content: (GarmentPhoto) -> Content
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = ProductDetailPhotoPresentation.compact.size
        layout.minimumLineSpacing = spacing
        layout.sectionInset = .init(top: topInset, left: 20, bottom: 0, right: 20)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.contentInsetAdjustmentBehavior = .never
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
        if let layout = view.collectionViewLayout as? UICollectionViewFlowLayout,
           layout.minimumLineSpacing != spacing || layout.sectionInset.top != topInset {
            layout.minimumLineSpacing = spacing
            layout.sectionInset = .init(top: topInset, left: 20, bottom: 0, right: 20)
            layout.invalidateLayout()
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
        private var dragImages: [UUID: UIImage] = [:]

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
                let ids = Set(photos.map(\.id))
                dragImages = dragImages.filter { ids.contains($0.key) && photoURLs[$0.key] == updatedURLs[$0.key] }
                photoURLs = updatedURLs
                collectionView?.reloadData()
            }
            if let leading = parent.leadingContent,
               let cell = collectionView?.cellForItem(at: IndexPath(item: 0, section: 0)) {
                cell.contentConfiguration = UIHostingConfiguration { leading }.margins(.all, 0)
            }
            if !isEnabled { activeDragID = nil }
        }

        private var photoOffset: Int { parent.leadingContent == nil ? 0 : 1 }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { photos.count + photoOffset }

        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath)
            if indexPath.item == 0, let leading = parent.leadingContent {
                cell.contentConfiguration = UIHostingConfiguration { leading }.margins(.all, 0)
                cell.backgroundConfiguration = .clear()
                return cell
            }
            let photoIndex = indexPath.item - photoOffset
            guard photos.indices.contains(photoIndex) else { return cell }
            let photo = photos[photoIndex]
            let id = photo.id
            let request = ProductThumbnailRequest(url: GarmentStore.url(for: photo), maximumPixelSize: 320)
            Task { @MainActor [weak self] in
                let decoded = await ProductThumbnailLoader.shared.image(for: request)
                guard let self, self.isActive, self.photos.contains(where: { $0.id == id }),
                      self.photoURLs[id] == request.url,
                      let decoded else { return }
                self.dragImages[id] = UIImage(cgImage: decoded.image)
            }
            cell.contentConfiguration = UIHostingConfiguration { parent.content(photo) }.margins(.all, 0)
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
            // Use a dedicated image preview rather than a snapshot of the
            // hosting cell, which also contains the removal button.
            item.previewProvider = { [weak self] in
                let size = ProductDetailPhotoPresentation.compact.size
                let imageView = UIImageView(frame: CGRect(origin: .zero, size: size))
                imageView.image = self?.dragImages[id] ?? UIImage(systemName: "photo")
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = 16
                let parameters = UIDragPreviewParameters()
                parameters.backgroundColor = .clear
                parameters.visiblePath = UIBezierPath(roundedRect: imageView.bounds,
                    cornerRadius: 16)
                return UIDragPreview(view: imageView, parameters: parameters)
            }
            session.localContext = self
            activeDragID = id
            feedback.prepare()
            return [item]
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
