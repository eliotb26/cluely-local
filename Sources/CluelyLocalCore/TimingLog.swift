import Foundation

/// One timed event: a transcribed clip or an answered question. Never holds what was said.
public struct TimingRecord: Equatable, Sendable {
    public enum Kind: String, Sendable { case clip, ask }

    public var date: Date
    public var kind: Kind
    public var speaker: Speaker?
    public var audioSeconds: Double?
    public var whisperMs: Int?
    /// Clip: last speech frame to transcript line written. Includes the 300 ms quiet the VAD waits for.
    public var lagMs: Int?
    /// Clip: clips waiting or in whisper when this one was queued, itself included.
    public var queued: Int?
    public var screenshotMs: Int?
    public var llmMs: Int?
    /// Ask: key press or command to answer printed.
    public var totalMs: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var costUSD: Double?
    /// live, file, cold (first clip after launch)
    public var note: String

    public init(date: Date, kind: Kind, note: String = "live") {
        self.date = date
        self.kind = kind
        self.note = note
    }

    public static let csvHeader =
        "timestamp,kind,speaker,audio_s,whisper_ms,lag_ms,queued,screenshot_ms,llm_ms,total_ms,input_tokens,output_tokens,cost_usd,note"

    public var csvRow: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func int(_ value: Int?) -> String { value.map(String.init) ?? "" }
        return [
            formatter.string(from: date), kind.rawValue, speaker?.rawValue ?? "",
            audioSeconds.map { String(format: "%.2f", $0) } ?? "",
            int(whisperMs), int(lagMs), int(queued), int(screenshotMs), int(llmMs), int(totalMs),
            int(inputTokens), int(outputTokens), costUSD.map { String(format: "%.5f", $0) } ?? "",
            note.replacingOccurrences(of: ",", with: ";"),
        ].joined(separator: ",")
    }
}

/// Appends rows to a CSV file, writing the header on first use.
public struct TimingLog: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ record: TimingRecord) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data((TimingRecord.csvHeader + "\n").utf8).write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((record.csvRow + "\n").utf8))
    }
}
