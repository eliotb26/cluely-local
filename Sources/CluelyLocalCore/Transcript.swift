import Foundation

/// One line of transcript.md: `- [14:03:27] Them: Can you hear me?`
public struct TranscriptLine: Equatable, Sendable {
    public let date: Date
    public let speaker: Speaker
    public let text: String

    public init(date: Date, speaker: Speaker, text: String) {
        self.date = date
        self.speaker = speaker
        self.text = text
    }

    public func formatted(timeZone: TimeZone = .current) -> String {
        "- [\(Transcript.formatter("HH:mm:ss", timeZone).string(from: date))] \(speaker.rawValue): \(text)"
    }
}

public enum Transcript {
    /// whisper.cpp's markers for silence or noise, and lines it invents on near-silence.
    public static let noise: Set<String> = [
        "[BLANK_AUDIO]", "[MUSIC]", "(music)", "[Music]", "(silence)", "[SILENCE]", "[NO SPEECH]",
    ]

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// `# Call, 2026-10-17 14:03`: written at the start of each session, and used to date the lines below it.
    public static func header(_ date: Date, timeZone: TimeZone = .current) -> String {
        "# Call, \(formatter("yyyy-MM-dd HH:mm", timeZone).string(from: date))"
    }

    /// Flattens whisper's line-per-segment output, strips noise markers and the dialogue dashes
    /// whisper sometimes adds. Empty means nothing was said.
    public static func clean(_ whisperOutput: String) -> String {
        let text = whisperOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !noise.contains($0) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
            .joined(separator: " ")
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : ""
    }

    /// Parses a whole transcript.md. Lines take their day from the nearest header above them.
    public static func parse(_ markdown: String, timeZone: TimeZone = .current) -> [TranscriptLine] {
        let headerFormat = formatter("yyyy-MM-dd HH:mm", timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var sessionStart: Date?
        var lines: [TranscriptLine] = []

        for raw in markdown.split(whereSeparator: \.isNewline).map(String.init) {
            if raw.hasPrefix("# Call, "), let date = headerFormat.date(from: String(raw.dropFirst(8))) {
                sessionStart = date
                continue
            }
            guard let sessionStart, let line = parseLine(raw, sessionStart: sessionStart, calendar: calendar) else { continue }
            lines.append(line)
        }
        return lines
    }

    /// A line earlier in the day than its session's header belongs to the next day (the call crossed midnight).
    static func parseLine(_ raw: String, sessionStart: Date, calendar: Calendar) -> TranscriptLine? {
        // "- [HH:mm:ss] Speaker: text"
        guard raw.hasPrefix("- ["), raw.count > 12 else { return nil }
        let chars = Array(raw)
        guard chars[11] == "]" else { return nil }
        let parts = String(chars[3..<11]).split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let rest = String(chars[12...]).trimmingCharacters(in: .whitespaces)
        for speaker in Speaker.allCases where rest.hasPrefix(speaker.rawValue + ": ") {
            let day = calendar.startOfDay(for: sessionStart)
            var date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: parts[2], of: day) ?? day
            if date < sessionStart {
                date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            }
            return TranscriptLine(date: date, speaker: speaker, text: String(rest.dropFirst(speaker.rawValue.count + 2)))
        }
        return nil
    }

    /// The lines from the last `window` seconds before `now`.
    public static func recent(_ lines: [TranscriptLine], now: Date, window: TimeInterval = 300) -> [TranscriptLine] {
        lines.filter { $0.date <= now && now.timeIntervalSince($0.date) <= window }
    }
}
