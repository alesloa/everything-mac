import Foundation
import Darwin

// Only the signal number delivered by the OS is stored by this C signal handler.
nonisolated(unsafe) private var interruptedSignal: sig_atomic_t = 0

enum CLISignals {
    static var cancelled: Bool { interruptedSignal != 0 }
    static var exitCode: Int32 { 128 + interruptedSignal }
    static func install() {
        signal(SIGPIPE, SIG_IGN)
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0 // Interrupt a blocked output write when cancelling.
        action.__sigaction_u.__sa_handler = { interruptedSignal = $0 }
        sigaction(SIGINT, &action, nil)
        sigaction(SIGTERM, &action, nil)
    }
}

enum CLIWriteError: Error { case closedPipe }

final class CLIOutput {
    private var buffer = Data()
    func append(_ data: Data) throws {
        if CLISignals.cancelled { throw CancellationError() }
        buffer.append(data)
        if buffer.count >= 64 * 1024 { try flush() }
    }
    func flush() throws {
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                if CLISignals.cancelled { throw CancellationError() }
                let written = Darwin.write(STDOUT_FILENO, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    if code == EPIPE { throw CLIWriteError.closedPipe }
                    // Source: the failed stdout write's actual POSIX errno.
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                if written == 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                offset += written
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }
    static func diagnostic(_ text: String) {
        let data = Data((text + "\n").utf8)
        _ = data.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress!, $0.count) }
    }
}
