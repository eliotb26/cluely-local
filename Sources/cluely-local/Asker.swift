import Foundation
import CluelyLocalCore

/// Screenshot + last 5 minutes of transcript + question → Claude Haiku.
/// Uses the Claude Code CLI (your existing plan), or the API when ANTHROPIC_API_KEY is set.
enum Asker {
    static let timeout: TimeInterval = 60
    static let screenshotMaxPixels = 1_600  // larger images cost tokens without helping
    static let apiModel = ProcessInfo.processInfo.environment["CLUELY_API_MODEL"] ?? "claude-haiku-4-5"

    struct Answer {
        var text = ""
        var screenshotMs = 0
        var llmMs = 0
        var inputTokens: Int?
        var outputTokens: Int?
        var costUSD: Double?
    }

    /// `screenshotTaken` runs once the screen is captured, so a "Thinking…" panel stays out of the shot.
    static func ask(_ question: String, transcriptURL: URL, screenshotTaken: () -> Void = {}) throws -> Answer {
        var answer = Answer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cluely-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shot = dir.appendingPathComponent("screen.png")
        let shotStarted = Date()
        let hasShot = (try? run(["screencapture", "-x", shot.path], timeout: 10)) != nil
            && FileManager.default.fileExists(atPath: shot.path)
        if hasShot {
            _ = try? run(["sips", "-Z", String(screenshotMaxPixels), shot.path], timeout: 10)
        } else {
            log("no screenshot: allow Screen Recording for your terminal app in System Settings")
        }
        answer.screenshotMs = milliseconds(since: shotStarted)
        screenshotTaken()

        let markdown = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let recent = Transcript.recent(Transcript.parse(markdown), now: Date(), window: AskPrompt.transcriptWindow)

        let llmStarted = Date()
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty {
            let prompt = AskPrompt.build(question: question, transcript: recent, screen: hasShot ? .attached : .none)
            try askAPI(prompt, image: hasShot ? shot : nil, key: key, into: &answer)
        } else {
            let prompt = AskPrompt.build(question: question, transcript: recent, screen: hasShot ? .file(shot.path) : .none)
            try askCLI(prompt, cwd: dir, into: &answer)
        }
        answer.llmMs = milliseconds(since: llmStarted)
        return answer
    }

    /// `claude -p` with only the Read tool, so it can open the screenshot. MCP servers are skipped for speed.
    private static func askCLI(_ prompt: String, cwd: URL, into answer: inout Answer) throws {
        let output = try run(["claude", "-p", "--model", "haiku", "--strict-mcp-config",
                              "--tools", "Read", "--allowedTools", "Read", "--output-format", "json"],
                             stdin: prompt, cwd: cwd, timeout: timeout)
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
            throw AppError.process("claude returned no JSON")
        }
        answer.text = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        answer.costUSD = json["total_cost_usd"] as? Double
        if let usage = json["usage"] as? [String: Any] {
            answer.inputTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { usage[$0] as? Int }.reduce(0, +)
            answer.outputTokens = usage["output_tokens"] as? Int
        }
    }

    /// Messages API, image inline. Cost isn't computed here; tokens are logged.
    private static func askAPI(_ prompt: String, image: URL?, key: String, into answer: inout Answer) throws {
        var content: [[String: Any]] = []
        if let image, let data = try? Data(contentsOf: image) {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                        "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt])
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": apiModel, "max_tokens": 400, "messages": [["role": "user", "content": content]],
        ])

        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(AppError.process("API call timed out"))
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = data.map { .success($0) } ?? .failure(error ?? AppError.process("empty API response"))
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout)

        guard let json = try JSONSerialization.jsonObject(with: try result.get()) as? [String: Any] else {
            throw AppError.process("API returned no JSON")
        }
        if let error = json["error"] as? [String: Any] {
            throw AppError.process("API: \(error["message"] as? String ?? "unknown error")")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        answer.text = blocks.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = json["usage"] as? [String: Any]
        answer.inputTokens = usage?["input_tokens"] as? Int
        answer.outputTokens = usage?["output_tokens"] as? Int
    }

    static func record(_ answer: Answer, totalMs: Int) -> TimingRecord {
        var record = TimingRecord(date: Date(), kind: .ask,
                                  note: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] == nil ? "cli" : "api")
        record.screenshotMs = answer.screenshotMs
        record.llmMs = answer.llmMs
        record.totalMs = totalMs
        record.inputTokens = answer.inputTokens
        record.outputTokens = answer.outputTokens
        record.costUSD = answer.costUSD
        return record
    }
}
