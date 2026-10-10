import Foundation

// Bounds private metadata publication, not authentication. A worker may finish
// a disk write after cancellation; its late result cannot reach the caller.
enum NativePendingPublicationOwner {
    static func perform(until deadline: ContinuousClock.Instant,
                        operation: @escaping @Sendable () throws -> NativePendingSnapshot) async throws -> NativePendingSnapshot {
        let owner = PendingPublicationCompletion(deadline: deadline)
        return try await withTaskCancellationHandler {
            let result = try await owner.wait(operation)
            guard !Task.isCancelled, ContinuousClock.now < deadline else { throw NativePendingError.outcomeUnknown }
            return result
        } onCancel: { owner.cancel() }
    }
}

private final class PendingPublicationCompletion: @unchecked Sendable, CustomReflectable {
    private let queue = DispatchQueue(label: "home.pending.publication.owner")
    private let deadline: ContinuousClock.Instant
    private var continuation: CheckedContinuation<NativePendingSnapshot, any Error>?
    private var task: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var cancelled = false
    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    func wait(_ operation: @escaping @Sendable () throws -> NativePendingSnapshot) async throws -> NativePendingSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                guard !cancelled, ContinuousClock.now < deadline else { finish(.failure(NativePendingError.outcomeUnknown)); return }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
                timer.setEventHandler { [weak self] in
                    guard let self, ContinuousClock.now >= deadline else { return }
                    finish(.failure(NativePendingError.outcomeUnknown))
                }
                self.timer = timer; timer.resume()
                task = Task.detached { [self] in
                    let result: Result<NativePendingSnapshot, any Error>
                    do { result = .success(try operation()) } catch { result = .failure(error) }
                    queue.async { [self] in
                        guard !stopped else { return }
                        guard !cancelled, ContinuousClock.now < deadline else { finish(.failure(NativePendingError.outcomeUnknown)); return }
                        finish(result)
                    }
                }
            }
        }
    }
    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { finish(.failure(NativePendingError.outcomeUnknown)) }
        }
    }
    private func finish(_ result: Result<NativePendingSnapshot, any Error>) {
        guard !stopped else { return }
        stopped = true; timer?.cancel(); timer = nil; task?.cancel(); task = nil
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }
}
