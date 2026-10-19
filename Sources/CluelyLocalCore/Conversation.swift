import Foundation

public enum Speaker: String, Equatable, Sendable, CaseIterable {
    case me = "Me"      // your microphone
    case them = "Them"  // everything your Mac plays: the call
}

public struct SpeakerClip: Equatable, Sendable {
    public let speaker: Speaker
    public let clip: Clip
}

/// Two VADs, one per source. Who said it comes from where the audio came from, not from voice matching.
///
/// Echo gate: while Them's voice is coming out of the speakers, and for `echoTail` after, mic frames
/// are dropped, so the call bouncing back into your mic isn't transcribed as you. A Me clip in
/// progress when the gate closes is ended and kept, not thrown away.
///
/// Cluely gates on Them's VAD state instead, which stays "speaking" through the 1.4 s quiet it waits
/// for before closing a clip. In a quick back-and-forth that swallows the start of your reply.
public struct Conversation: Sendable {
    public static let defaultEchoTail = 0.3

    public var echoGate: Bool
    public let echoTail: Double
    public private(set) var droppedMicFrames = 0
    private var lastThemVoice = -Double.infinity

    private var me: Segmenter
    private var them: Segmenter
    private var meScorer = EnergyScorer()
    private var themScorer = EnergyScorer()

    public init(config: VADConfig = VADConfig(), echoGate: Bool = true, echoTail: Double = defaultEchoTail) {
        self.me = Segmenter(config: config)
        self.them = Segmenter(config: config)
        self.echoGate = echoGate
        self.echoTail = echoTail
    }

    public func isMicGated(at time: Double) -> Bool {
        echoGate && time - lastThemVoice <= echoTail
    }

    /// Scores a frame by loudness and feeds it.
    public mutating func push(_ speaker: Speaker, frame: [Float], time: Double) -> [SpeakerClip] {
        let probability = speaker == .me ? meScorer.probability(frame) : themScorer.probability(frame)
        return push(speaker, frame: frame, probability: probability, time: time)
    }

    /// Feeds a frame with a probability from any scorer (energy here, or Silero).
    public mutating func push(_ speaker: Speaker, frame: [Float], probability: Double, time: Double) -> [SpeakerClip] {
        switch speaker {
        case .them:
            let wasGated = isMicGated(at: time)
            if probability >= me.config.positiveThreshold { lastThemVoice = time }
            var out: [SpeakerClip] = []
            if !wasGated, isMicGated(at: time), let clip = me.flush(time: time) {
                out.append(SpeakerClip(speaker: .me, clip: clip))
            }
            if let clip = them.push(frame, probability: probability, time: time) {
                out.append(SpeakerClip(speaker: .them, clip: clip))
            }
            return out
        case .me:
            if isMicGated(at: time) {
                droppedMicFrames += 1
                me.reset()
                return []
            }
            return me.push(frame, probability: probability, time: time).map { [SpeakerClip(speaker: .me, clip: $0)] } ?? []
        }
    }

    /// Closes both streams, e.g. at the end of a file or on quit.
    public mutating func flush(time: Double) -> [SpeakerClip] {
        [(Speaker.me, me.flush(time: time)), (.them, them.flush(time: time))]
            .compactMap { speaker, clip in clip.map { SpeakerClip(speaker: speaker, clip: $0) } }
    }
}

/// What happens when clips arrive faster than whisper can transcribe them.
/// Cluely skips a clip when 4 are already in flight; cluely-local queues by default.
public enum OverloadPolicy: Equatable, Sendable {
    case queue
    case drop(maxInFlight: Int)
}

public struct Backlog: Equatable, Sendable {
    public let policy: OverloadPolicy
    public private(set) var inFlight = 0
    public private(set) var peakInFlight = 0
    public private(set) var accepted = 0
    public private(set) var dropped = 0

    public init(policy: OverloadPolicy = .queue) {
        self.policy = policy
    }

    /// Returns false if the clip should be dropped. Otherwise counts it as in flight.
    public mutating func offer() -> Bool {
        if case .drop(let limit) = policy, inFlight >= limit {
            dropped += 1
            return false
        }
        inFlight += 1
        accepted += 1
        peakInFlight = max(peakInFlight, inFlight)
        return true
    }

    public mutating func finish() {
        inFlight = max(inFlight - 1, 0)
    }
}
