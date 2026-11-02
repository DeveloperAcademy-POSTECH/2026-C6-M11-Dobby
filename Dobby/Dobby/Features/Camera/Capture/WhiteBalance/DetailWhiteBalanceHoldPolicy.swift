// Created by mason on 11/1/26.
import Foundation

/// 장면을 자동 판별하지 않는다. 최근 안정된 WB를 첫 촬영/줌 조작에서만 유지한다.
nonisolated struct DetailWhiteBalanceHoldPolicy {
    enum State: String { case automatic, locking, held }
    private(set) var state: State = .automatic
    private(set) var revision = 0
    private var startedAt: TimeInterval = 0
    private var observedAt: TimeInterval = -.infinity
    private var stable = false
    private var stability = DetailWhiteBalanceStability()

    mutating func reset(at time: TimeInterval) {
        revision += 1
        state = .automatic
        startedAt = time
        observedAt = -.infinity
        stable = false
        stability = .init()
    }

    mutating func observe(at time: TimeInterval, zoom: Double, adjusting: Bool, gains: [Float]) {
        guard state == .automatic else { return }
        stable = stability.observe(time: time, zoom: zoom, adjusting: adjusting, gains: gains)
        observedAt = time
    }

    mutating func requestLock(at time: TimeInterval) -> Int? {
        guard state == .automatic, stable, time - startedAt >= 3,
              time >= observedAt, time - observedAt <= 0.5 else { return nil }
        state = .locking
        return revision
    }

    mutating func confirm(revision expected: Int) -> Bool {
        guard revision == expected, state == .locking else { return false }
        state = .held
        return true
    }
}
