import Foundation

/// Lance un programme du système, attend sa fin et rend sa sortie d'erreur. Sans terminal, sans entrée.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let errorOutput: String
    }

    struct CapturedOutput: Sendable {
        let status: Int32
        let standardOutput: String
        let errorOutput: String
    }

    /// Termine le programme s'il dépasse `timeout` ou si la tâche est annulée.
    static func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: Duration) async -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish = Once(continuation)
                process.terminationHandler = { finished in
                    let data = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
                    finish.resume(Output(status: finished.terminationStatus, errorOutput: String(decoding: data, as: UTF8.self)))
                }
                do {
                    try process.run()
                } catch {
                    finish.resume(Output(status: -1, errorOutput: "Impossible de lancer \(executable.lastPathComponent) : \(error.localizedDescription)"))
                    return
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Variante utilisée par les adaptateurs de CLI : conserve stdout et stderr et peut être annulée.
    static func runCapturingOutput(_ executable: URL, arguments: [String], environment: [String: String] = [:], timeout: Duration) async -> CapturedOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.isEmpty ? nil : environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let outputBuffer = CapturedBytes()
        let errorBuffer = CapturedBytes()
        let readers = DispatchGroup()
        readers.enter()
        readers.enter()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish = OnceCaptured(continuation)
                process.terminationHandler = { finished in
                    readers.wait()
                    let output = outputBuffer.data
                    let errors = errorBuffer.data
                    finish.resume(CapturedOutput(status: finished.terminationStatus,
                                                 standardOutput: String(decoding: output, as: UTF8.self),
                                                 errorOutput: String(decoding: errors, as: UTF8.self)))
                }
                do {
                    try process.run()
                    DispatchQueue.global().async {
                        outputBuffer.data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                        readers.leave()
                    }
                    DispatchQueue.global().async {
                        errorBuffer.data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                        readers.leave()
                    }
                } catch {
                    finish.resume(CapturedOutput(status: -1, standardOutput: "", errorOutput: error.localizedDescription))
                    return
                }
                Task.detached {
                    try? await Task.sleep(for: timeout)
                    if process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Une continuation ne se reprend qu'une fois : la fin du programme et l'échec du lancement peuvent se croiser.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Output, Never>?

        init(_ continuation: CheckedContinuation<Output, Never>) { self.continuation = continuation }

        func resume(_ output: Output) {
            let pending = lock.withLock { () -> CheckedContinuation<Output, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: output)
        }
    }

    private final class OnceCaptured: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CapturedOutput, Never>?

        init(_ continuation: CheckedContinuation<CapturedOutput, Never>) { self.continuation = continuation }

        func resume(_ output: CapturedOutput) {
            let pending = lock.withLock { () -> CheckedContinuation<CapturedOutput, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: output)
        }
    }

    private final class CapturedBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        var data: Data {
            get { lock.withLock { bytes } }
            set { lock.withLock { bytes = newValue } }
        }
    }
}
