import Foundation

// Capacity belongs to actual filesystem work. A canceled network syscall still
// holds its slot until it returns, even if its panel has already closed.
public actor BackgroundFileJobLimiter {
    private let maximum: Int
    private var active = 0
    private var waiting: [Waiter] = []
    var state: (active: Int, queued: Int) { (active, waiting.count) }

    private struct Waiter {
        let id: UUID
        let cancellation: BackgroundFileJobCancellation
        let continuation: CheckedContinuation<Bool, Never>
    }

    public init(maximumActive: Int) { maximum = max(1, maximumActive) }

    /// Forward task cancellation to the supplied token using a task cancellation
    /// handler; the fallback is returned for canceled jobs that have not started.
    public func withPermit<Value: Sendable>(cancellation: BackgroundFileJobCancellation,
                                           cancelled: @Sendable () -> Value,
                                           operation: @Sendable () async -> Value) async -> Value {
        guard await acquire(cancellation) else { return cancelled() }
        guard !cancellation.isCancelled else { release(); return cancelled() }
        let value = await operation()
        release()
        return value
    }

    private func acquire(_ cancellation: BackgroundFileJobCancellation) async -> Bool {
        guard !cancellation.isCancelled else { return false }
        let id = UUID()
        cancellation.whenCancelled { Task { await self.cancelWaiter(id) } }
        return await withCheckedContinuation { continuation in
            if cancellation.isCancelled { continuation.resume(returning: false) }
            else if active < maximum {
                active += 1
                continuation.resume(returning: true)
            } else { waiting.append(Waiter(id: id, cancellation: cancellation, continuation: continuation)) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiting.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        active -= 1
        while !waiting.isEmpty {
            let waiter = waiting.removeFirst()
            if waiter.cancellation.isCancelled { waiter.continuation.resume(returning: false); continue }
            active += 1
            waiter.continuation.resume(returning: true)
            break
        }
    }
}

/// Bridges task cancellation into non-cancelable filesystem calls and queued jobs.
public final class BackgroundFileJobCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [@Sendable () -> Void] = []
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        let callbacks = lock.withLock {
            cancelled = true
            let callbacks = observers
            observers.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }
    func whenCancelled(_ callback: @escaping @Sendable () -> Void) {
        let callNow = lock.withLock {
            if cancelled { return true }
            observers.append(callback)
            return false
        }
        if callNow { callback() }
    }
}
