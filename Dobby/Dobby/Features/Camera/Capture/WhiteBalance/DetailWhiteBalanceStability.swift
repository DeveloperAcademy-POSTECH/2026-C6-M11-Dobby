// Created by mason on 10/31/26.
import Foundation

/// 진단용 관찰 기준. 실제 노출 시점의 안정성이나 색 정확도를 보장하지 않는다.
nonisolated struct DetailWhiteBalanceStability {
    private var anchor: [Float] = []
    private var stableSince: TimeInterval?
    private var previousTime: TimeInterval?

    mutating func observe(time: TimeInterval, zoom: Double, adjusting: Bool, gains: [Float]) -> Bool {
        guard time.isFinite, zoom.isFinite, zoom > 0, !adjusting,
              gains.count == 3, gains.allSatisfy({ $0.isFinite && $0 >= 1 }) else {
            self = Self()
            return false
        }
        let continuous = previousTime.map { time > $0 && time - $0 <= 0.5 } ?? false
        let unchanged = anchor.count == 3 && zip(anchor, gains).allSatisfy { abs($0 - $1) / $0 <= 0.01 }
        if !continuous || !unchanged { anchor = gains; stableSince = time }
        previousTime = time
        return stableSince.map { time - $0 >= 1 } ?? false
    }
}
