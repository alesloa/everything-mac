import Testing
import Foundation
@testable import IndexCore

@Test func backgroundLimiterRetainsCancelledActiveWorkAndRemovesCancelledQueue() async throws {
    let limiter = BackgroundFileJobLimiter(maximumActive: 1)
    let heldGate = BackgroundLimiterGate()
    let activeCancellation = BackgroundFileJobCancellation()
    let held = Task {
        await limiter.withPermit(cancellation: activeCancellation, cancelled: { false }) {
            await heldGate.wait()
            return true
        }
    }
    while await !heldGate.started { try await Task.sleep(for: .milliseconds(1)) }
    let queuedCancellation = BackgroundFileJobCancellation()
    let queuedGate = BackgroundLimiterGate()
    let queued = Task {
        await limiter.withPermit(cancellation: queuedCancellation, cancelled: { false }) {
            await queuedGate.wait()
            return true
        }
    }
    while await limiter.state.queued != 1 { try await Task.sleep(for: .milliseconds(1)) }
    activeCancellation.cancel()
    queuedCancellation.cancel()
    #expect(await queued.value == false)
    #expect(await queuedGate.started == false)
    #expect(await limiter.state.active == 1)
    #expect(await limiter.state.queued == 0)
    let nextGate = BackgroundLimiterGate()
    let next = Task {
        await limiter.withPermit(cancellation: BackgroundFileJobCancellation(), cancelled: { false }) {
            await nextGate.wait()
            return true
        }
    }
    while await limiter.state.queued != 1 { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await nextGate.started == false)
    await heldGate.release()
    #expect(await held.value)
    while await !nextGate.started { try await Task.sleep(for: .milliseconds(1)) }
    await nextGate.release()
    #expect(await next.value)
    #expect(await limiter.state.active == 0)
}

@Test func backgroundLimiterRejectsAlreadyCancelledJobWithoutStartingWork() async {
    let limiter = BackgroundFileJobLimiter(maximumActive: 2)
    let token = BackgroundFileJobCancellation()
    token.cancel()
    let result = await limiter.withPermit(cancellation: token, cancelled: { false }) { true }
    #expect(!result)
    #expect(await limiter.state.active == 0)
    #expect(await limiter.state.queued == 0)
}

private actor BackgroundLimiterGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
