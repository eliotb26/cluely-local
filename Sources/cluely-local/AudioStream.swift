import Foundation
import CluelyLocalCore

/// A child process that writes 16 kHz mono 16-bit PCM to stdout, cut into VAD frames.
/// Them: audiotee (Core Audio taps, macOS 14.2+). Me: ffmpeg reading the default mic.
final class AudioStream {
    static let bytesPerSecond = 32_000.0

    let speaker: Speaker
    private let process = Process()
    private let frameBytes: Int
    private var pending = Data()
    private var stopping = false

    init(speaker: Speaker, arguments: [String], frameSamples: Int) {
        self.speaker = speaker
        self.frameBytes = frameSamples * 2
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
    }

    static func them(audiotee: URL, pid: Int32?, mute: Bool, frameSamples: Int) -> AudioStream {
        // 50 ms chunks, as Cluely runs it.
        var args = [audiotee.path, "--sample-rate", "16000", "--chunk-duration", "0.05"]
        if let pid { args += ["--include-processes", String(pid)] }
        if mute { args.append("--mute") }
        return AudioStream(speaker: .them, arguments: args, frameSamples: frameSamples)
    }

    static func me(device: String, frameSamples: Int) -> AudioStream {
        AudioStream(speaker: .me, arguments: ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "avfoundation",
                                              "-i", ":" + device, "-ac", "1", "-ar", "16000", "-f", "s16le", "-"],
                    frameSamples: frameSamples)
    }

    /// Calls `onFrame` on `queue` with each frame and the wall-clock time its last sample was captured.
    func start(on queue: DispatchQueue, onFrame: @escaping ([Float], Double) -> Void) throws {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let name = speaker.rawValue
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let arrived = Date().timeIntervalSince1970
            queue.async { self?.consume(data, arrived: arrived, onFrame: onFrame) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            // audiotee logs JSON lines; surface only errors.
            for line in String(decoding: handle.availableData, as: UTF8.self).split(separator: "\n")
            where line.contains("\"error\"") || !line.hasPrefix("{") {
                log("\(name) audio: \(line.prefix(300))")
            }
        }
        process.terminationHandler = { [weak self] process in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            if self?.stopping != true {
                log("\(name) audio stopped with status \(process.terminationStatus)")
            }
        }
        try process.run()
    }

    func stop() {
        stopping = true
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data, arrived: Double, onFrame: ([Float], Double) -> Void) {
        pending.append(data)
        while pending.count >= frameBytes {
            let frame = WAV.floats(fromPCM16: pending.prefix(frameBytes))
            pending.removeFirst(frameBytes)
            // Later bytes in the same read were captured later: back-date this frame by what's left.
            onFrame(frame, arrived - Double(pending.count) / Self.bytesPerSecond)
        }
    }
}
