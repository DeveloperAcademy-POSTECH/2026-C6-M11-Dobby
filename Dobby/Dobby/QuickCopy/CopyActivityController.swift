import ActivityKit
import Observation
import Foundation

@MainActor @Observable
final class CopyActivityController {
    private(set) var session: ProductCopySession?
    private(set) var busy = false
    var errorMessage: String?

    init() { refresh() }

    func refresh() {
        guard let saved = ProductCopyStore.load(),
              Activity<ProductCopyAttributes>.activities.contains(where: {
                  $0.attributes.sessionID == saved.id && ($0.activityState == .active || $0.activityState == .stale)
              }) else {
            session = nil
            ProductCopyStore.invalidate()
            return
        }
        session = saved
    }

    @discardableResult
    func start(product: ExportProduct) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        refresh()
        if let session, session.productID == product.id, session.payload == product.fruits { return true }
        // 다른 상품의 활동은 권한 상태와 관계없이 먼저 무효화한다.
        ProductCopyStore.invalidate()
        session = nil
        for activity in Activity<ProductCopyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = "실시간 현황을 사용할 수 없습니다. 아래 상품 정보에서 필요한 항목을 복사할 수 있어요."
            return false
        }
        let next = ProductCopySession(id: UUID(), channel: .fruits, productID: product.id,
                                      payload: product.fruits, createdAt: Date())
        do {
            try ProductCopyStore.save(next)
            _ = try Activity.request(attributes: ProductCopyAttributes(sessionID: next.id, channelName: next.channel.title),
                                     content: ActivityContent(state: .init(), staleDate: next.createdAt.addingTimeInterval(8 * 3600)), pushType: nil)
            session = next
            errorMessage = nil
            return true
        } catch {
            ProductCopyStore.invalidate()
            errorMessage = "복사 도우미를 시작하지 못했어요. 다시 시도하거나 아래에서 상품 정보를 복사해주세요."
            return false
        }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        ProductCopyStore.invalidate()
        session = nil
        for activity in Activity<ProductCopyAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        busy = false
    }
}
