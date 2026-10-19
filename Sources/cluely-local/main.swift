import AppKit
import CluelyLocalCore

// cluely-local: transcribe the call (Me = mic, Them = system audio), ask Claude about it with ⌘⏎.

let panelSeconds: TimeInterval = 30
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let model = root.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
let audiotee = root.appendingPathComponent("bin/audiotee")
let transcriptURL = root.appendingPathComponent("transcript.md")
let timingLog = TimingLog(url: root.appendingPathComponent("runs.csv"))

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    log("\(error)\n\n\(Options.usage)")
    exit(2)
}
if options.showHelp {
    print(Options.usage)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let panel = options.window ? AnswerPanel() : nil
var hotkey: Hotkey? // kept for the life of the app

/// Runs one ask off the main thread, prints the answer, shows it, logs the timing.
func ask(_ question: String, then finished: @escaping () -> Void = {}) {
    let started = Date()
    DispatchQueue.global().async {
        do {
            let answer = try Asker.ask(question, transcriptURL: transcriptURL) {
                DispatchQueue.main.async { panel?.show("Thinking…") }
            }
            let total = milliseconds(since: started)
            print("\n\(answer.text)\n")
            fflush(stdout)
            log(String(format: "answered in %.2fs (screenshot %dms, claude %dms), %@ in / %@ out tokens, %@",
                       Double(total) / 1000, answer.screenshotMs, answer.llmMs,
                       answer.inputTokens.map(String.init) ?? "?", answer.outputTokens.map(String.init) ?? "?",
                       answer.costUSD.map { String(format: "$%.4f", $0) } ?? "cost unknown"))
            try? timingLog.append(Asker.record(answer, totalMs: total))
            DispatchQueue.main.async { panel?.show(answer.text); finished() }
        } catch {
            log("ask failed: \(error)")
            DispatchQueue.main.async { panel?.show("Couldn't get an answer: \(error)"); finished() }
        }
    }
}

switch options.command {
case .ask(let question):
    ask(question) {
        guard let panel else { exit(0) }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel.window,
                                               queue: .main) { _ in exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + panelSeconds) { exit(0) }
    }

case .listen:
    guard FileManager.default.fileExists(atPath: model.path) else {
        log("model missing at \(model.path). Run ./scripts/setup.sh from the repo root first.")
        exit(1)
    }
    let listener = Listener(options: options, model: model, audiotee: audiotee,
                            transcriptURL: transcriptURL, timingLog: timingLog)
    let quit = {
        listener.stop { summary in
            log(summary)
            exit(0)
        }
    }

    if let file = options.file {
        DispatchQueue.global().async {
            do { try listener.transcribeFile(file) } catch { log("could not read \(file): \(error)"); exit(1) }
            quit()
        }
    } else {
        guard FileManager.default.isExecutableFile(atPath: audiotee.path) else {
            log("audiotee missing at \(audiotee.path). Run ./scripts/setup.sh from the repo root first.")
            exit(1)
        }
        do { try listener.start() } catch { log("could not start audio: \(error)"); exit(1) }

        hotkey = Hotkey { ask(AskPrompt.defaultQuestion) }
        if hotkey == nil { log("⌘⏎ is taken by another app; use `cluely-local ask` instead") }
        log("listening: Them = system audio\(options.mic ? ", Me = microphone" : ""). ⌘⏎ to ask, Ctrl+C to stop.")

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { quit() }
        interrupt.resume()
        if let seconds = options.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { quit() }
        }
    }
}

app.run()
