import SwiftData
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Dobby

/// Render the real card so a correct model date cannot pass with a missing or
/// truncated footer. Preview photos are test-owned and removed after each test.
@MainActor
final class ProductLibraryRegistrationDateTests: XCTestCase {
    func testCompletedDraftRendersCompletionDateAtTheBottomOfANarrowCard() async throws {
        let fixture = try Fixture()
        defer { fixture.removePhotos() }
        fixture.garment.createdAt = localDate(year: 2026, month: 10, day: 1)
        fixture.garment.informationCompletedAt = localDate(year: 2026, month: 11, day: 9)

        for (typeSize, name) in [(DynamicTypeSize.large, "completed-normal"),
                                 (.accessibility5, "completed-largest-type")] {
            let rendered = try await render(fixture.garment, typeSize: typeSize, name: name)
            let date = try XCTUnwrap(rendered.text.first { $0.value == "2026.11.09" },
                "The entire completion date must remain readable: \(rendered.text.map(\.value))")
            XCTAssertFalse(rendered.text.contains { $0.value == "2026.10.01" })
            XCTAssertGreaterThan(date.bounds.minX, 0, "The footer must stay inside the card.")
            XCTAssertLessThan(date.bounds.maxX, 1)
            XCTAssertGreaterThan(date.bounds.minY, 0)
            XCTAssertLessThan(date.bounds.maxY, 0.15, "The date belongs below the platform badges.")
        }
    }

    func testLegacyProductRendersCreationDateInGregorianFormat() async throws {
        let fixture = try Fixture()
        defer { fixture.removePhotos() }
        fixture.garment.createdAt = localDate(year: 2026, month: 10, day: 1)
        fixture.garment.informationCompletedAt = nil
        fixture.garment.creationDraftData = nil

        let rendered = try await render(fixture.garment, name: "legacy-gregorian",
            locale: Locale(identifier: "ar_SA"), calendar: Calendar(identifier: .islamicUmmAlQura))
        XCTAssertTrue(rendered.text.contains { $0.value == "2026.10.01" },
            "The design's Gregorian date should not change with the user's calendar: \(rendered.text.map(\.value))")
    }

    func testSavedDraftDoesNotRenderOrReserveARegistrationFooter() async throws {
        let fixture = try Fixture()
        defer { fixture.removePhotos() }
        fixture.garment.createdAt = localDate(year: 2026, month: 10, day: 1)
        fixture.garment.informationCompletedAt = localDate(year: 2026, month: 11, day: 9)
        let completed = try await render(fixture.garment, name: "completed-before-draft-comparison")

        fixture.garment.informationCompletedAt = nil
        fixture.garment.creationDraftData = try JSONEncoder().encode(ProductCreationDraft(
            step: .information, measurementRecordID: UUID(), photoState: nil,
            measurementInputData: nil, savedAt: localDate(year: 2026, month: 11, day: 8)))
        let draft = try await render(fixture.garment, name: "draft", showsDraftPlaceholders: true)
        XCTAssertFalse(draft.text.isEmpty,
            "Verify that card content actually rendered: \(draft.text.map(\.value))")
        XCTAssertFalse(draft.text.contains { $0.value.contains("2026.") },
            "A saved draft has no first-registration date: \(draft.text.map(\.value))")
        XCTAssertEqual(completed.size.height - draft.size.height, 24, accuracy: 0.5,
            "The hidden date's 16pt line and 8pt gap must not leave a blank footer.")
    }

    private func render(_ garment: Garment, typeSize: DynamicTypeSize = .large,
                        name: String, showsDraftPlaceholders: Bool = false,
                        locale: Locale = Locale(identifier: "ko_KR"),
                        calendar: Calendar = Calendar(identifier: .gregorian)) async throws -> RenderedCard {
        let card = ProductLibraryCard(garment: garment, showsDraftPlaceholders: showsDraftPlaceholders)
            .frame(width: 175)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.locale, locale)
            .environment(\.calendar, calendar)
            .environment(\.colorScheme, .light)
        let measuringController = UIHostingController(rootView: card)
        let size = measuringController.sizeThatFits(in: CGSize(width: 175, height: 2_000))
        XCTAssertEqual(size.width, 175, accuracy: 0.5)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: card
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea())
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.layoutIfNeeded()
        // Allow the stored thumbnail's asynchronous load and SwiftUI layout to finish.
        try await Task.sleep(for: .milliseconds(350))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "archive-registration-\(name)-175pt"
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL.temporaryDirectory.appending(path: "dobby-archive-registration", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(name)-175pt.png")
        try XCTUnwrap(image.pngData()).write(to: file)
        print("Archive registration snapshot: \(file.path)")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { observation -> RecognizedText? in
            guard let value = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedText(value: value.filter { !$0.isWhitespace }, bounds: observation.boundingBox)
        }
        return RenderedCard(size: size, text: text)
    }

    private func localDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private struct RecognizedText {
        let value: String
        let bounds: CGRect
    }

    private struct RenderedCard {
        let size: CGSize
        let text: [RecognizedText]
    }

    private struct Fixture {
        let container: ModelContainer
        let garment: Garment
        let photoURLs: [URL]

        init() throws {
            container = LibraryPreviewData.makeContainer()
            let garments = try container.mainContext.fetch(FetchDescriptor<Garment>())
            garment = try XCTUnwrap(garments.first { $0.brand == "Bape" })
            photoURLs = garments.flatMap(\.photos).map { GarmentStore.url(for: $0) }
        }

        func removePhotos() {
            for url in photoURLs { try? FileManager.default.removeItem(at: url) }
        }
    }
}
