import Foundation

enum AppError: Error, CustomStringConvertible {
    case audio(String)
    case process(String)

    var description: String {
        switch self {
        case .audio(let message): return "audio: \(message)"
        case .process(let message): return "process: \(message)"
        }
    }
}

/// Runs a command found on PATH, optionally feeding stdin, and returns trimmed stdout.
/// Kills the process and throws if it outlives `timeout`.
func run(_ arguments: [String], stdin: String? = nil, cwd: URL? = nil, timeout: TimeInterval) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    if let cwd { process.currentDirectoryURL = cwd }

    let stdoutPipe = Pipe(), stderrPipe = Pipe(), stdinPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe
    try process.run()

    // Drain both pipes concurrently so a chatty process can't fill one and block. stdin is written
    // on its own queue too, so the timeout covers it. If the process has already died (say `claude`
    // isn't installed), the write fails with EPIPE, which the throwing write reports instead of crashing.
    let group = DispatchGroup()
    var stdoutData = Data(), stderrData = Data()
    DispatchQueue.global().async(group: group) { stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: group) { stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile() }
    DispatchQueue.global().async(group: group) {
        let input = stdinPipe.fileHandleForWriting
        if let stdin { try? input.write(contentsOf: Data(stdin.utf8)) }
        try? input.close()
    }

    guard group.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        throw AppError.process("\(arguments[0]) timed out after \(Int(timeout))s")
    }
    process.waitUntilExit()

    if process.terminationStatus == 127 {
        throw AppError.process("\(arguments[0]) not found. Is it installed and on your PATH?")
    }
    guard process.terminationStatus == 0 else {
        let message = String(decoding: stderrData, as: UTF8.self).prefix(300)
        throw AppError.process("\(arguments[0]) exited \(process.terminationStatus): \(message)")
    }
    return String(decoding: stdoutData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// True if `command` resolves on PATH.
func isInstalled(_ command: String) -> Bool {
    (try? run(["which", command], timeout: 5)) != nil
}

/// Creates `url` readable only by you, if it doesn't exist yet. Transcripts are private.
func createPrivateFile(_ url: URL, contents: Data = Data()) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    guard FileManager.default.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
        throw AppError.process("couldn't create \(url.path)")
    }
}

func milliseconds(since date: Date) -> Int {
    Int(Date().timeIntervalSince(date) * 1000)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[cluely-local] \(message)\n".utf8))
}
