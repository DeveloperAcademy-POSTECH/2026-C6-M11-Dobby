import Foundation

/// Session changes and photo capture invalidate commands which have not reached
/// the serial camera queue yet. The lock protects only small in-memory checks;
/// it is never held while asking AVFoundation to configure a device.
nonisolated final class DetailCameraControlEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = UUID()

    func ticket() -> DetailCameraControlTicket {
        lock.withLock { DetailCameraControlTicket(owner: self, epoch: epoch) }
    }

    func invalidate() { lock.withLock { epoch = UUID() } }

    fileprivate func isCurrent(_ value: UUID) -> Bool { lock.withLock { epoch == value } }
}

nonisolated final class DetailCameraControlTicket: @unchecked Sendable {
    private let owner: DetailCameraControlEpoch
    private let epoch: UUID
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(owner: DetailCameraControlEpoch, epoch: UUID) {
        self.owner = owner
        self.epoch = epoch
    }

    func cancel() { lock.withLock { cancelled = true } }

    func checkCancellation() throws {
        guard !lock.withLock({ cancelled }), owner.isCurrent(epoch) else { throw CancellationError() }
    }
}
