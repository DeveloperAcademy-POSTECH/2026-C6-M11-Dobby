import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
@testable import Dobby

@MainActor
struct ProductPhotoFlowHandoffTests {
    @Test func maximumSelectionPersistsOnlyChosenPhotosInSelectionOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let details = try (0..<11).map { _ in try fixture.detail(input: input, shade: .blue) }
        let model = try ProductPhotoModel(input: input, captureProvider: DetailStub(assets: details))
        for _ in details { try await model.captureDetail() }
        let selected = Array(details.prefix(10).reversed())
        for photo in selected { model.toggleSelection(photo.id) }
        #expect(model.toggleSelection(details[10].id) == .limitReached)
        let output = try #require(model.output)
        try await fixture.apply(output, input: input)
        let durable = ModelContext(fixture.container)
        let stored = try #require(durable.fetch(FetchDescriptor<Garment>()).first)
        #expect(stored.productPhotos.map(\.id) == selected.map(\.id))
        #expect(stored.thumbnail?.id == selected[0].id)
        #expect(stored.photos.count == 11, "선택한 10장과 보정 근거인 실측 원본만 저장")
        #expect(stored.measurementPhoto?.id == fixture.measured.id)
        #expect(stored.measurementPhoto?.isSelectedForProduct == false)
        #expect(stored.measurement("totalLength")?.valueCm == 63.25)
        #expect(!stored.photos.contains { $0.id == details[10].id })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 11)
        // 미선택 원본은 저장 결과에서 제외되며, 임시 원본 정리는 별도 완료 단계의 책임이다.
        for photo in details {
            guard case let .localFile(url, _) = photo.source else { Issue.record("실제 파일 fixture 필요"); continue }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func measuredSourceIsSeededWithoutCopyingOrLosingGeometry() throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        #expect(input.garmentID == fixture.garment.id)
        #expect(input.measurement.id == fixture.measured.id)
        #expect(input.measurement.purpose == .measurement)
        #expect(fixture.measured.landmarks.count == 1)
        guard case let .localFile(url, metadata) = input.measurement.source else {
            Issue.record("A measured input needs the existing original file")
            return
        }
        #expect(url == fixture.photosDirectory.appending(path: fixture.measured.fileName))
        #expect(metadata.pixelWidth == 32 && metadata.pixelHeight == 24)
        #expect(metadata.orientation == .up)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 1)
    }

    @Test func chosenOrderAndRepresentativePersistWithoutDuplicateSource() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let first = try fixture.detail(input: input, shade: .red)
        let second = try fixture.detail(input: input, shade: .green)
        let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [first, second], selectedPhotos: [second, input.measurement, first],
            representativePhotoID: second.id)
        try await fixture.apply(output, input: input)
        #expect(fixture.garment.productPhotos.map(\.id) == [second.id, fixture.measured.id, first.id])
        #expect(fixture.garment.thumbnail?.id == second.id)
        #expect(fixture.garment.photos.count == 3)
        #expect(fixture.garment.measurementPhoto === fixture.measured)
        #expect(fixture.measured.landmarks[0].x == 0.2)
        #expect(fixture.measured.landmarks[0].isMoved)
        #expect(fixture.garment.orderedMeasurements.first?.valueCm == 63.25)
        // Reapplying the same completion does not re-encode, add rows, or add files.
        try await fixture.apply(output, input: input)
        #expect(fixture.garment.photos.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 3)
        let durable = ModelContext(fixture.container)
        let stored = try #require(durable.fetch(FetchDescriptor<Garment>()).first)
        #expect(stored.productPhotos.map(\.id) == [second.id, fixture.measured.id, first.id])
        #expect(stored.measurementPhoto?.landmarks[0].isMoved == true)
        #expect(stored.measurement("totalLength")?.valueCm == 63.25)
        let storedFirst = try #require(stored.photos.first { $0.id == first.id })
        guard case let .localFile(original, _) = first.source else { return }
        #expect(try Data(contentsOf: fixture.photosDirectory.appending(path: storedFirst.fileName)) == Data(contentsOf: original))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func deselectedMeasurementRemainsCorrectionEvidenceButNotProductPhoto() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let selected = try fixture.detail(input: input, shade: .blue)
        let notSelected = try fixture.detail(input: input, shade: .yellow)
        let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [notSelected, selected], selectedPhotos: [selected], representativePhotoID: selected.id)
        try await fixture.apply(output, input: input)
        #expect(fixture.garment.productPhotos.map(\.id) == [selected.id])
        #expect(fixture.measured.isSelectedForProduct == false)
        #expect(fixture.garment.measurementPhoto === fixture.measured)
        #expect(fixture.measured.landmarks.count == 1)
        #expect(fixture.garment.photos.count == 2)
        guard case let .localFile(url, _) = notSelected.source else { return }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func wrongSessionAndForeignPhotoFailBeforeAnyChange() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let detail = try fixture.detail(input: input, shade: .red)
        let wrongSession = ProductPhotoOutput(sessionID: UUID(), garmentID: input.garmentID,
            detailPhotos: [detail], selectedPhotos: [detail], representativePhotoID: detail.id)
        await #expect(throws: ProductPhotoHandoff.HandoffError.self) { try await fixture.apply(wrongSession, input: input) }
        let unknown = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [], selectedPhotos: [detail], representativePhotoID: detail.id)
        await #expect(throws: ProductPhotoHandoff.HandoffError.self) { try await fixture.apply(unknown, input: input) }
        #expect(fixture.garment.photos.count == 1)
        #expect(fixture.measured.role == .thumbnail && fixture.measured.isSelectedForProduct == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 1)
    }

    @Test func failedCopyCleansOnlyNewDestinationsAndRetainsDraftAndSources() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let first = try fixture.detail(input: input, shade: .red)
        let missing = try fixture.detail(input: input, shade: .green)
        let originalMeasurement = try Data(contentsOf: fixture.photosDirectory.appending(path: fixture.measured.fileName))
        guard case let .localFile(missingURL, _) = missing.source,
              case let .localFile(firstURL, _) = first.source else { return }
        try FileManager.default.removeItem(at: missingURL)
        let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [first, missing], selectedPhotos: [first, missing], representativePhotoID: first.id)
        await #expect(throws: (any Error).self) { try await fixture.apply(output, input: input) }
        #expect(fixture.garment.photos.count == 1 && fixture.measured.role == .thumbnail)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try Data(contentsOf: fixture.photosDirectory.appending(path: fixture.measured.fileName)) == originalMeasurement)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 1)
    }

    @Test func destinationCollisionPreservesExistingBytesAndCleansEarlierNewCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let first = try fixture.detail(input: input, shade: .red)
        let collision = try fixture.detail(input: input, shade: .green)
        let existingBytes = Data("An existing file must never be replaced".utf8)
        let collisionURL = fixture.photosDirectory.appending(path: "\(fixture.garment.id.uuidString)-\(collision.id.uuidString).jpg")
        try existingBytes.write(to: collisionURL)
        let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [first, collision], selectedPhotos: [first, collision], representativePhotoID: first.id)
        await #expect(throws: ProductPhotoHandoff.HandoffError.self) { try await fixture.apply(output, input: input) }
        #expect(try Data(contentsOf: collisionURL) == existingBytes)
        #expect(fixture.garment.photos.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 2)
        guard case let .localFile(original, _) = first.source else { return }
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func failedSaveRestoresRelationshipsSelectionAndFilesWithoutGlobalRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let detail = try fixture.detail(input: input, shade: .blue)
        let output = ProductPhotoOutput(sessionID: input.sessionID, garmentID: input.garmentID,
            detailPhotos: [detail], selectedPhotos: [detail], representativePhotoID: detail.id)
        enum SaveFailure: Error { case unavailable }
        await #expect(throws: SaveFailure.self) {
            try await ProductPhotoHandoff.apply(output, to: fixture.garment, in: fixture.context,
                input: input, photosDirectory: fixture.photosDirectory,
                persist: { _ in throw SaveFailure.unavailable })
        }
        #expect(fixture.garment.photos.map(\.id) == [fixture.measured.id])
        #expect(fixture.measured.role == .thumbnail && fixture.measured.isSelectedForProduct == nil)
        #expect(fixture.measured.landmarks.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.photosDirectory.path).count == 1)
        try await fixture.apply(output, input: input)
        #expect(fixture.garment.productPhotos.map(\.id) == [detail.id])
    }

    @Test func initialMeasurementSelectionAndMoveUseTheSameOutputRepresentative() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let provider = DetailStub(assets: [try fixture.detail(input: input, shade: .red),
                                           try fixture.detail(input: input, shade: .green)])
        let model = try ProductPhotoModel(input: input, captureProvider: provider,
                                          initialSelectedPhotoIDs: [input.measurement.id])
        #expect(model.output?.selectedPhotos == [input.measurement])
        try await model.captureDetail()
        try await model.captureDetail()
        model.detailPhotos.forEach { model.toggleSelection($0.id) }
        let last = model.detailPhotos[1].id
        model.moveSelection(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.output?.representativePhotoID == last)
        #expect(model.output?.selectedPhotos.map(\.id) == [last, input.measurement.id, model.detailPhotos[0].id])
        let previous = model.selectedPhotoIDs
        model.moveSelection(fromOffsets: IndexSet(integer: 20), toOffset: 0)
        #expect(model.selectedPhotoIDs == previous)
    }

    @Test func cancelledDraftDiscardsOnlyDetailsAndRejectsLateProviderResponses() async throws {
        let fixture = try Fixture()
        defer { fixture.removeFiles() }
        let input = try fixture.input()
        let first = try fixture.detail(input: input, shade: .red)
        let late = try fixture.detail(input: input, shade: .green)
        let provider = DetailStub(assets: [first, late])
        let model = try ProductPhotoModel(input: input, captureProvider: provider)
        try await model.captureDetail()
        provider.suspend = true
        let task = Task { try await model.captureDetail() }
        await provider.waitUntilStarted()
        try await model.discardUncommittedDetails()
        provider.complete()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(model.detailPhotos.isEmpty)
        #expect(Set(provider.discarded) == Set([first.id, late.id]))
        #expect(!provider.discarded.contains(input.measurement.id))
        #expect(FileManager.default.fileExists(atPath: fixture.photosDirectory.appending(path: fixture.measured.fileName).path))
    }

    private final class DetailStub: CaptureProviding {
        var assets: [CapturedAsset]
        var discarded: [UUID] = []
        var suspend = false
        private var pending: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        init(assets: [CapturedAsset]) { self.assets = assets }
        func capture(sessionID: UUID, garmentID: UUID) async throws -> CapturedAsset {
            let asset = assets.removeFirst()
            if suspend {
                await withCheckedContinuation { continuation in
                    pending = continuation; started?.resume(); started = nil
                }
            }
            return asset
        }
        func discardUncommitted(_ asset: CapturedAsset) async throws { discarded.append(asset.id) }
        func waitUntilStarted() async {
            if pending == nil { await withCheckedContinuation { started = $0 } }
        }
        func complete() { pending?.resume(); pending = nil }
    }

    private struct Fixture {
        let directory: URL
        let photosDirectory: URL
        let container: ModelContainer
        let context: ModelContext
        let garment: Garment
        let measured: GarmentPhoto
        let sessionID = UUID()
        init() throws {
            directory = URL.temporaryDirectory.appending(path: "Dobby-photo-handoff-\(UUID().uuidString)", directoryHint: .isDirectory)
            photosDirectory = directory.appending(path: "photos", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
            container = try ModelContainer(for: Garment.self, GarmentPhoto.self, MeasuredValue.self,
                LandmarkPoint.self, ExportRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            context = ModelContext(container)
            context.autosaveEnabled = false
            garment = Garment(category: "Shirt", group: .top)
            measured = GarmentPhoto(fileName: "original.jpg", role: .thumbnail, order: 0, isMeasurementSource: true)
            let landmark = LandmarkPoint(name: "leftShoulder", index: 0, x: 0.2, y: 0.3)
            landmark.x = 0.2
            landmark.isMoved = true
            measured.landmarks = [landmark]
            garment.photos = [measured]
            garment.measurements = [MeasuredValue(key: "totalLength", label: "총장", displayOrder: 0,
                                                  valueCm: 63.25, autoValueCm: 61)]
            context.insert(garment)
            try Self.jpeg(.gray).write(to: photosDirectory.appending(path: measured.fileName))
            try context.save()
        }
        func input() throws -> ProductPhotoInput {
            try ProductPhotoHandoff.makeInput(for: garment, sessionID: sessionID, photosDirectory: photosDirectory)
        }
        func detail(input: ProductPhotoInput, shade: UIColor) throws -> CapturedAsset {
            let id = UUID()
            let url = directory.appending(path: "detail-\(id.uuidString).jpg")
            try Self.jpeg(shade).write(to: url)
            return CapturedAsset(id: id, sessionID: input.sessionID, garmentID: input.garmentID,
                purpose: .detail, capturedAt: .now, source: .localFile(url, metadata: .init(
                    pixelWidth: 32, pixelHeight: 24, contentType: "public.jpeg", orientation: .up)))
        }
        func apply(_ output: ProductPhotoOutput, input: ProductPhotoInput) async throws {
            try await ProductPhotoHandoff.apply(output, to: garment, in: context, input: input, photosDirectory: photosDirectory)
        }
        func removeFiles() { try? FileManager.default.removeItem(at: directory) }
        static func jpeg(_ color: UIColor) throws -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).jpegData(withCompressionQuality: 0.9) {
                color.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            }
        }
    }
}
