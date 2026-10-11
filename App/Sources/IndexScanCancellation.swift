import Foundation

// A detached filesystem walk does not inherit its caller's task cancellation.
// Both the actor generation and its caller can stop the same worker cooperatively.
final class IndexScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
