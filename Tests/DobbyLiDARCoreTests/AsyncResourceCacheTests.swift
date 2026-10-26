import Foundation
import XCTest
@testable import DobbyLiDARCore

/// Deterministic ownership and scheduling checks with an explicitly suspended
/// fake loader. These do not measure real model, camera or device startup time.
@MainActor
final class AsyncResourceCacheTests: XCTestCase {
    func testConcurrentCallersShareOneLoadAndLaterCallsReuseTheSameResource() async throws {
        let gate = ResourceLoadGate()
        let resource = CachedTestResource()
        let cache = AsyncResourceCache { try await gate.load() }
        let callers = (0..<20).map { _ in Task { try await cache.value() } }
        await eventually { await gate.loadCount == 1 }
        await gate.succeed(resource, attempt: 1)

        for caller in callers {
            let loaded = try await caller.value
            XCTAssertTrue(loaded === resource)
        }
        for _ in 0..<5 {
            let loaded = try await cache.value()
            XCTAssertTrue(loaded === resource)
        }
        let count = await gate.loadCount
        XCTAssertEqual(count, 1)
    }

    func testFailedLoadIsReleasedSoTheNextRequestCanRetryAndCacheSuccess() async throws {
        let gate = ResourceLoadGate()
        let resource = CachedTestResource()
        let cache = AsyncResourceCache { try await gate.load() }
        let first = Task { try await cache.value() }
        await eventually { await gate.loadCount == 1 }
        await gate.fail(attempt: 1)
        do {
            _ = try await first.value
            XCTFail("The failed load must reach its caller")
        } catch {
            XCTAssertEqual(error as? ResourceLoadFailure, .expected)
        }

        let retry = Task { try await cache.value() }
        await eventually { await gate.loadCount == 2 }
        await gate.succeed(resource, attempt: 2)
        let loaded = try await retry.value
        XCTAssertTrue(loaded === resource)
        let reused = try await cache.value()
        XCTAssertTrue(reused === resource)
        let count = await gate.loadCount
        XCTAssertEqual(count, 2)
    }

    func testLateFailuresCannotClearTheNewRetryLoad() async throws {
        let gate = ResourceLoadGate()
        let resource = CachedTestResource()
        let cache = AsyncResourceCache { try await gate.load() }
        let callers = (0..<32).map { _ in
            Task {
                do { return try await cache.value() }
                catch ResourceLoadFailure.expected { return try await cache.value() }
            }
        }
        await eventually { await gate.loadCount == 1 }
        await gate.fail(attempt: 1)
        await eventually { await gate.loadCount == 2 }
        await gate.succeed(resource, attempt: 2)
        for caller in callers {
            let loaded = try await caller.value
            XCTAssertTrue(loaded === resource)
        }
        let count = await gate.loadCount
        XCTAssertEqual(count, 2, "An old failure must not evict a newer pending task")
    }

    func testCancellingOneWaiterDoesNotCancelSharedLoadOrPublishSuccessToThatWaiter() async throws {
        let gate = ResourceLoadGate()
        let resource = CachedTestResource()
        let cache = AsyncResourceCache { try await gate.load() }
        let cancelled = Task { try await cache.value() }
        let survivor = Task { try await cache.value() }
        await eventually { await gate.loadCount == 1 }
        cancelled.cancel()
        await gate.succeed(resource, attempt: 1)

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled screen must not receive the eventual resource")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let loaded = try await survivor.value
        XCTAssertTrue(loaded === resource)
        let reused = try await cache.value()
        XCTAssertTrue(reused === resource)
        let count = await gate.loadCount
        let loaderWasCancelled = await gate.loaderWasCancelled
        XCTAssertEqual(count, 1)
        XCTAssertFalse(loaderWasCancelled)
    }

    func testAlreadyCancelledCallerDoesNotStartALoad() async {
        let gate = ResourceLoadGate()
        let cache = AsyncResourceCache { try await gate.load() }
        let caller = Task { try await cache.value() }
        caller.cancel()
        do {
            _ = try await caller.value
            XCTFail("Cancellation must be checked before creating the shared task")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let count = await gate.loadCount
        XCTAssertEqual(count, 0)
    }

    func testLoaderSynchronousPrefixRunsOffTheMainThreadForAMainActorCaller() async throws {
        let cache = AsyncResourceCache { cacheLoaderIsOnMainThread() }
        let ranOnMainThread = try await cache.value()
        XCTAssertFalse(ranOnMainThread,
                       "A main-actor view must not synchronously construct resources on its own executor")
    }

    func testOptionalNilIsAReusableSuccessfulResource() async throws {
        let counter = ResourceLoadCounter()
        let cache = AsyncResourceCache<Int?> {
            await counter.increment()
            return nil
        }
        let first = try await cache.value()
        let second = try await cache.value()
        XCTAssertNil(first)
        XCTAssertNil(second)
        let count = await counter.count
        XCTAssertEqual(count, 1, "A successful nil payload is distinct from an empty cache")
    }

    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not complete within three seconds", file: file, line: line)
    }
}

private actor CachedTestResource {}
private enum ResourceLoadFailure: Error { case expected }

/// Inspect only the loader's synchronous entry, before any suspension. This
/// intentionally tests thread placement without dispatching work to an actor.
private nonisolated func cacheLoaderIsOnMainThread() -> Bool { Thread.isMainThread }

private actor ResourceLoadGate {
    private(set) var loadCount = 0
    private(set) var loaderWasCancelled = false
    private var pending: [Int: CheckedContinuation<CachedTestResource, Error>] = [:]

    func load() async throws -> CachedTestResource {
        loadCount += 1
        let attempt = loadCount
        let resource: CachedTestResource = try await withCheckedThrowingContinuation {
            pending[attempt] = $0
        }
        loaderWasCancelled = loaderWasCancelled || Task.isCancelled
        try Task.checkCancellation()
        return resource
    }

    func succeed(_ resource: CachedTestResource, attempt: Int) {
        pending.removeValue(forKey: attempt)?.resume(returning: resource)
    }

    func fail(attempt: Int) {
        pending.removeValue(forKey: attempt)?.resume(throwing: ResourceLoadFailure.expected)
    }
}

private actor ResourceLoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
