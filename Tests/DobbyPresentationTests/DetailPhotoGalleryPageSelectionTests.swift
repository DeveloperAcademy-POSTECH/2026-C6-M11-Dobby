import Testing
import SwiftUI
import UIKit
@testable import Dobby

struct DetailPhotoGalleryPageSelectionTests {
    @Test func deletingInteriorPhotoAdvancesToItsNextNeighbour() throws {
        let selection = try #require(DetailPhotoGalleryPageSelection(focusedID: "b", currentID: "b",
            previousIDs: ["a", "b", "c", "d"], ids: ["a", "c", "d"]))
        #expect(selection.id == "c")
        #expect(!selection.movesBackwards)
    }

    @Test func deletingLastPhotoMovesBackwardsAndEmptyGalleryHasNoDestination() throws {
        let selection = try #require(DetailPhotoGalleryPageSelection(focusedID: "c", currentID: "c",
            previousIDs: ["a", "b", "c"], ids: ["a", "b"]))
        #expect(selection.id == "b")
        #expect(selection.movesBackwards)
        #expect(DetailPhotoGalleryPageSelection(focusedID: "a", currentID: "a",
            previousIDs: ["a"], ids: []) == nil)
    }

    @Test func completedDeletionUsesTheSameDirectionAfterFocusHasAlreadyBeenUpdated() throws {
        let next = try #require(DetailPhotoGalleryPageSelection(focusedID: "c", currentID: "b",
            previousIDs: ["a", "b", "c"], ids: ["a", "c"]))
        #expect(next.id == "c" && !next.movesBackwards)
        let previous = try #require(DetailPhotoGalleryPageSelection(focusedID: "a", currentID: "c",
            previousIDs: ["a", "b", "c"], ids: ["a", "b"]))
        #expect(previous.id == "a" && previous.movesBackwards)
    }

    @Test func unchangedPhotosPreserveFocusAndThumbnailNavigationDirection() throws {
        let ids = ["a", "b", "c"]
        let unchanged = try #require(DetailPhotoGalleryPageSelection(focusedID: "b", currentID: "b",
            previousIDs: ids, ids: ids))
        #expect(unchanged.id == "b")
        let backward = try #require(DetailPhotoGalleryPageSelection(focusedID: "a", currentID: "b",
            previousIDs: ids, ids: ids))
        #expect(backward.id == "a" && backward.movesBackwards)
    }

    @MainActor
    @Test func cancelledNativeSwipeKeepsSelectionAndDeletionReusesTheAdjacentPage() throws {
        struct Photo: Identifiable { let id: String }
        var focusedID = "b"
        let selection = Binding(get: { focusedID }, set: { focusedID = $0 })
        let pager = DetailPhotoGalleryPager(items: ["a", "b", "c"].map { Photo(id: $0) },
            focusedID: selection, reduceMotion: true, onTransitionChanged: { _ in }) { Text($0.id) }
        let coordinator = pager.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        controller.dataSource = coordinator
        controller.delegate = coordinator
        coordinator.update(pager, in: controller)
        let original = try #require(controller.viewControllers?.first)
        let next = try #require(coordinator.pageViewController(controller, viewControllerAfter: original))
        coordinator.pageViewController(controller, willTransitionTo: [next])
        coordinator.pageViewController(controller, didFinishAnimating: true,
            previousViewControllers: [original], transitionCompleted: false)
        #expect(focusedID == "b")
        #expect(controller.viewControllers?.first === original)

        focusedID = "c"
        let afterDeletion = DetailPhotoGalleryPager(items: ["a", "c"].map { Photo(id: $0) },
            focusedID: selection, reduceMotion: true, onTransitionChanged: { _ in }) { Text($0.id) }
        coordinator.update(afterDeletion, in: controller)
        #expect(controller.viewControllers?.first === next,
            "Reuse the loaded neighbour instead of flashing an empty/recreated page")
        #expect(coordinator.pageViewController(controller, viewControllerAfter: next) == nil)
        let previous = try #require(coordinator.pageViewController(controller, viewControllerBefore: next))
        #expect(coordinator.pageViewController(controller, viewControllerBefore: previous) == nil)
    }
}
