// Created by mason on 10/21/26.
import Foundation

/// Driver의 직렬 큐에서만 사용. 중단·교체된 요청의 늦은 콜백은 무시한다.
nonisolated final class DetailExposureCompletion {
    private var pending: (id: UUID, completion: (Result<Double, Error>) -> Void)?
    var isPending: Bool { pending != nil }
    func begin(_ completion: @escaping (Result<Double, Error>) -> Void) -> UUID {
        cancel()
        let id = UUID()
        pending = (id, completion)
        return id
    }
    func finish(_ id: UUID, with result: Result<Double, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.completion(result)
    }
    func cancel() {
        guard let current = pending else { return }
        finish(current.id, with: .failure(CancellationError()))
    }
}
