import XCTest
@testable import Dobby

/// Exercises the shared channel contract with unsaved model instances. No
/// ModelContainer, persistent storage or external export is involved.
@MainActor
final class ExportChannelCompatibilityTests: XCTestCase {
    func testSharedChannelsRoundTripAndTrackSuccessfulGarmentExports() throws {
        let channels = ExportChannel.allCases
        XCTAssertEqual(Set(channels.map(\.rawValue)), ["instagram", "naverStore", "cafe24", "fruitsFamily"],
            "Existing channel identifiers must remain compatible with saved records")
        XCTAssertEqual(ExportChannel.availableCases, [.instagram, .cafe24, .fruitsFamily])
        XCTAssertFalse(ExportChannel.availableCases.contains(.naverStore),
            "The legacy Naver identifier must not make the removed export feature visible")
        for (index, channel) in channels.enumerated() {
            let data = try JSONEncoder().encode(channel)
            let decoded = try JSONDecoder().decode(ExportChannel.self, from: data)
            XCTAssertEqual(decoded, channel)

            let record = ExportRecord(channel: decoded, succeeded: true)
            XCTAssertEqual(record.channelRaw, channel.rawValue)
            XCTAssertEqual(record.channel, channel)
            let garment = Garment(category: "T-shirt", group: .top)
            XCTAssertFalse(garment.hasExported(to: channel))
            garment.exports = [record]
            XCTAssertTrue(garment.hasExported(to: channel))

            let replacement = channels[(index + 1) % channels.count]
            record.channel = replacement
            XCTAssertEqual(record.channelRaw, replacement.rawValue)
            XCTAssertEqual(record.channel, replacement)
            XCTAssertFalse(garment.hasExported(to: channel))
            XCTAssertTrue(garment.hasExported(to: replacement))

            record.succeeded = false
            XCTAssertFalse(garment.hasExported(to: replacement), "A failed attempt must not mark the channel as exported")
        }
    }
}
