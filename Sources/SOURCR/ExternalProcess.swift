import Darwin
import Foundation

enum ExternalProcessError: Error {
    case timedOut(TimeInterval)
    case failed(status: Int32, stderr: String)
}

/// Shared read-only CLI runner for `git` / `gh`.
///
/// Captures stdout/stderr via temp files and waits on the caller thread with a
/// private-queue watchdog. Avoids Pipe buffer deadlocks and GCD “wait for another
/// pool thread to signal exit” false-timeouts.
enum ExternalProcess {
    private static let watchdogQueue = DispatchQueue(label: "com.sourcr.process.watchdog")

    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> String {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appendingPathComponent("sourcr-proc-out-\(UUID().uuidString)")
        let errURL = fm.temporaryDirectory.appendingPathComponent("sourcr-proc-err-\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        process.environment = environment
        process.standardOutput = outHandle
        process.standardError = errHandle

        let timedOutFlag = TimeoutFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: watchdogQueue)
        watchdog.setEventHandler {
            timedOutFlag.mark()
            if process.isRunning {
                process.terminate()
            }
        }
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.resume()
        defer { watchdog.cancel() }

        try process.run()
        process.waitUntilExit()

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        try? outHandle.close()
        try? errHandle.close()

        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""

        if timedOutFlag.triggered {
            throw ExternalProcessError.timedOut(timeout)
        }

        if process.terminationStatus != 0 {
            throw ExternalProcessError.failed(
                status: process.terminationStatus,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return out
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var triggered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
