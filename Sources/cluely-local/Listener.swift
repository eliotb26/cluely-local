import Foundation
import CluelyLocalCore

/// Runs both audio streams through the VADs, transcribes each finished clip with whisper.cpp
/// one at a time, and appends `- [time] Me/Them: text` lines to transcript.md.
final class Listener {
    static let whisperTimeout: TimeInterval = 60

    private let options: Options
    private let model: URL
    private let audiotee: URL
    private let transcriptURL: URL
    private let timingLog: TimingLog
    private let config = VADConfig()

    private let vadQueue = DispatchQueue(label: "cluely-local.vad")       // owns `conversation`
    private let work = DispatchQueue(label: "cluely-local.whisper")       // one whisper at a time
    private let lock = NSLock()                                          // guards `backlog`, `firstClip`
    private var conversation: Conversation
    private var backlog: Backlog
    private var firstClip = true
    private var streams: [AudioStream] = []

    init(options: Options, model: URL, audiotee: URL, transcriptURL: URL, timingLog: TimingLog) {
        self.options = options
        self.model = model
        self.audiotee = audiotee
        self.transcriptURL = transcriptURL
        self.timingLog = timingLog
        self.conversation = Conversation(config: config, echoGate: options.echoGate)
        self.backlog = Backlog(policy: options.policy)
    }

    func start() throws {
        try appendToTranscript("\n\(Transcript.header(Date()))\n\n")
        var all = [AudioStream.them(audiotee: audiotee, pid: options.themPID, mute: options.muteThem,
                                    frameSamples: config.frameSamples)]
        if options.mic { all.append(.me(device: options.micDevice, frameSamples: config.frameSamples)) }
        for stream in all {
            let speaker = stream.speaker
            try stream.start(on: vadQueue) { [weak self] frame, time in
                guard let self else { return }
                self.dispatch(self.conversation.push(speaker, frame: frame, time: time), note: "live")
            }
        }
        streams = all
    }

    /// Feeds an audio file through the same pipeline as Them, as fast as the VAD can read it.
    /// Times are synthetic (file position from now), so no lag is logged.
    func transcribeFile(_ path: String) throws {
        try appendToTranscript("\n\(Transcript.header(Date()))\n\n")
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("cluely-local-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        _ = try run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", path,
                     "-ac", "1", "-ar", "16000", "-f", "s16le", raw.path], timeout: 120)
        let samples = WAV.floats(fromPCM16: try Data(contentsOf: raw))
        let start = Date().timeIntervalSince1970
        vadQueue.sync {
            var offset = 0
            while offset + config.frameSamples <= samples.count {
                let frame = Array(samples[offset..<offset + config.frameSamples])
                offset += config.frameSamples
                let time = start + Double(offset) / Double(config.sampleRate)
                dispatch(conversation.push(.them, frame: frame, time: time), note: "file")
            }
            dispatch(conversation.flush(time: start + Double(offset) / Double(config.sampleRate)), note: "file")
        }
    }

    /// Stops capture, transcribes what's left, then calls `done` with a one-line summary.
    func stop(done: @escaping (String) -> Void) {
        streams.forEach { $0.stop() }
        vadQueue.async {
            self.dispatch(self.conversation.flush(time: Date().timeIntervalSince1970), note: "live")
            let dropped = self.conversation.droppedMicFrames
            self.work.async {
                let summary = self.lock.withLock {
                    "clips transcribed \(self.backlog.accepted), dropped \(self.backlog.dropped), " +
                        "peak in flight \(self.backlog.peakInFlight), mic frames gated while Them spoke \(dropped)"
                }
                done(summary)
            }
        }
    }

    private func dispatch(_ clips: [SpeakerClip], note: String) {
        for item in clips {
            let queued: Int? = lock.withLock { backlog.offer() ? backlog.inFlight : nil }
            guard let queued else {
                log("dropped a \(item.speaker.rawValue) clip: whisper is busy (--drop-at \(options.dropAt ?? 0))")
                continue
            }
            work.async { self.transcribe(item, queued: queued, note: note) }
        }
    }

    private func transcribe(_ item: SpeakerClip, queued: Int, note: String) {
        defer { lock.withLock { backlog.finish() } }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("cluely-local-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            try WAV.encode(item.clip.samples).write(to: wav)
            let started = Date()
            let output = try run(["whisper-cli", "-m", model.path, "-f", wav.path, "-l", options.language, "-nt", "-np"],
                                 timeout: Self.whisperTimeout)
            let whisperMs = milliseconds(since: started)
            let text = Transcript.clean(output)
            guard !text.isEmpty else { return log("\(item.speaker.rawValue): heard nothing") }

            let spokenAt = Date(timeIntervalSince1970: item.clip.closedTime - item.clip.seconds)
            let line = TranscriptLine(date: spokenAt, speaker: item.speaker, text: text).formatted()
            try appendToTranscript(line + "\n")
            print(line)
            fflush(stdout)

            let isCold = lock.withLock { () -> Bool in defer { firstClip = false }; return firstClip }
            var record = TimingRecord(date: Date(), kind: .clip, note: isCold ? "\(note) cold" : note)
            record.speaker = item.speaker
            record.audioSeconds = item.clip.seconds
            record.whisperMs = whisperMs
            record.queued = queued
            if note == "live" { record.lagMs = Int((Date().timeIntervalSince1970 - item.clip.speechEndTime) * 1000) }
            try? timingLog.append(record)
        } catch {
            log("\(item.speaker.rawValue) clip failed: \(error)")
        }
    }

    private func appendToTranscript(_ text: String) throws {
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            try Data().write(to: transcriptURL)
        }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
