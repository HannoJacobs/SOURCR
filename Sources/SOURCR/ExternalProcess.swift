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

    /// SIGTERM first so the child can clean up; this long later it gets SIGKILL.
    private static let killGracePeriod: TimeInterval = 2

    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> String {
        try execute(executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                    environment: environment, timeout: timeout) { url in
            String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
        }
    }

    /// Reads at most `maxBytes` of stdout, so a huge result cannot fill memory.
    static func runCapped(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String],
        timeout: TimeInterval,
        maxBytes: Int
    ) throws -> CappedOutput {
        try execute(executable: executable, arguments: arguments, currentDirectory: currentDirectory,
                    environment: environment, timeout: timeout) { url in
            let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
            guard total > 0, let handle = try? FileHandle(forReadingFrom: url) else {
                return CappedOutput(text: "", totalBytes: total)
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: min(maxBytes, total))) ?? Data()
            let kept = data.count < total ? data.upToLastNewline : data
            return CappedOutput(text: String(decoding: kept, as: UTF8.self), totalBytes: total)
        }
    }

    private static func execute<Output>(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        environment: [String: String],
        timeout: TimeInterval,
        readOutput: (URL) -> Output
    ) throws -> Output {
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
            guard process.isRunning else { return }
            process.terminate()
            // waitUntilExit below cannot return until the child dies, so escalate from here.
            watchdogQueue.asyncAfter(deadline: .now() + killGracePeriod) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.resume()
        defer { watchdog.cancel() }

        try process.run()
        process.waitUntilExit()

        try? outHandle.close()
        try? errHandle.close()

        // Lossy on purpose: one non-UTF-8 byte must not blank a whole status or diff.
        let err = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)

        if timedOutFlag.triggered {
            throw ExternalProcessError.timedOut(timeout)
        }

        if process.terminationStatus != 0 {
            throw ExternalProcessError.failed(
                status: process.terminationStatus,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return readOutput(outURL)
    }
}

struct CappedOutput: Sendable {
    let text: String
    let totalBytes: Int
    var isTruncated: Bool { text.utf8.count < totalBytes }
}

extension Data {
    /// Everything through the last newline, or all of it when there is none, so a cut
    /// never ends mid-line or inside a multi-byte character.
    var upToLastNewline: Data {
        guard let newline = lastIndex(of: 0x0A) else { return self }
        return Data(self[startIndex...newline])
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
