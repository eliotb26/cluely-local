import Foundation

/// Voice activity settings: the ones Cluely 2.1.20 runs Silero VAD with.
/// Cluely calls `NonRealTimeVAD.new({redemptionMs: 300, preSpeechPadMs: 300})`; the thresholds and the
/// 400 ms minimum are vad-web's defaults. (vad-web's own defaults for the other two are 1,400 and 800 ms.)
public struct VADConfig: Equatable, Sendable {
    public var sampleRate = 16_000
    public var frameSamples = 512          // 32 ms, Silero's frame size at 16 kHz
    public var positiveThreshold = 0.3     // a frame at or above this is speech
    public var negativeThreshold = 0.25    // a frame below this counts towards ending the clip
    public var preSpeechPadMs = 300        // audio kept from before speech started
    public var redemptionMs = 300          // quiet needed before a clip ends
    public var minSpeechMs = 400           // shorter clips are thrown away as misfires
    public var maxClipMs = 20_000          // hard cap per clip

    public init() {}

    public var frameMs: Double { Double(frameSamples) * 1000 / Double(sampleRate) }
    func frames(_ ms: Int) -> Int { Int((Double(ms) / frameMs).rounded(.up)) }
}

/// A finished stretch of speech, ready for whisper.
public struct Clip: Equatable, Sendable {
    public let samples: [Float]
    /// Wall-clock time (seconds since 1970) of the last frame at or above the positive threshold.
    public let speechEndTime: Double
    /// Wall-clock time of the frame that closed the clip.
    public let closedTime: Double
    public let speechFrames: Int
    /// True when the clip was cut at the hard cap rather than by a pause.
    public let capped: Bool

    public var seconds: Double { Double(samples.count) / 16_000 }
}

/// Turns per-frame speech probabilities into clips, with Silero-style hysteresis:
/// start at >= positive, end after `redemptionMs` of frames below negative.
public struct Segmenter: Sendable {
    public let config: VADConfig
    public private(set) var isSpeaking = false

    private var preBuffer: [[Float]] = []
    private var current: [Float] = []
    private var currentFrames = 0
    private var speechFrames = 0
    private var redemption = 0
    private var lastSpeechTime = 0.0

    public init(config: VADConfig = VADConfig()) {
        self.config = config
    }

    /// Feeds one frame. `time` is when the frame finished, in seconds. Returns a clip when one closes.
    public mutating func push(_ frame: [Float], probability: Double, time: Double) -> Clip? {
        guard isSpeaking else {
            if probability >= config.positiveThreshold {
                isSpeaking = true
                current = preBuffer.flatMap { $0 }
                currentFrames = preBuffer.count
                preBuffer = []
                return append(frame, probability: probability, time: time)
            }
            preBuffer.append(frame)
            if preBuffer.count > config.frames(config.preSpeechPadMs) { preBuffer.removeFirst() }
            return nil
        }
        return append(frame, probability: probability, time: time)
    }

    /// Ends any clip in progress, keeping it if it had enough speech.
    public mutating func flush(time: Double) -> Clip? {
        defer { reset() }
        return isSpeaking ? finish(time: time, capped: false) : nil
    }

    /// Drops everything, including the pre-speech pad.
    public mutating func reset() {
        isSpeaking = false
        preBuffer = []
        current = []
        currentFrames = 0
        speechFrames = 0
        redemption = 0
    }

    private mutating func append(_ frame: [Float], probability: Double, time: Double) -> Clip? {
        current += frame
        currentFrames += 1
        if probability >= config.positiveThreshold {
            speechFrames += 1
            redemption = 0
            lastSpeechTime = time
        } else if probability < config.negativeThreshold {
            redemption += 1
            if redemption >= config.frames(config.redemptionMs) {
                defer { reset() }
                return finish(time: time, capped: false)
            }
        }
        if currentFrames >= config.frames(config.maxClipMs) {
            // Keep listening: the speaker is still going, so the next clip starts straight away.
            let clip = finish(time: time, capped: true)
            current = []
            currentFrames = 0
            speechFrames = 0
            redemption = 0
            return clip
        }
        return nil
    }

    private func finish(time: Double, capped: Bool) -> Clip? {
        guard speechFrames >= config.frames(config.minSpeechMs) else { return nil }
        return Clip(samples: current, speechEndTime: lastSpeechTime, closedTime: time,
                    speechFrames: speechFrames, capped: capped)
    }
}

/// A stand-in for Silero: maps frame loudness above a tracked noise floor to a 0...1 "probability".
/// 0 at 6 dB above the floor, 1 at 21 dB above it. The floor starts at the first frame's level,
/// so a noisy room isn't scored as speech while the floor catches up.
public struct EnergyScorer: Sendable {
    public static let floorLimitDb = -60.0
    public static let startDb = 6.0
    public static let rangeDb = 15.0
    /// How fast the floor rises towards louder frames (per frame). It falls instantly.
    public static let riseRate = 0.002

    public private(set) var noiseFloorDb = floorLimitDb
    private var started = false

    public init() {}

    public static func rmsDb(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return -120 }
        let meanSquare = frame.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame.count)
        return 10 * log10(max(meanSquare, 1e-12))
    }

    public mutating func probability(_ frame: [Float]) -> Double {
        let db = Self.rmsDb(frame)
        if !started {
            started = true
            noiseFloorDb = max(db, Self.floorLimitDb)
        } else if db < noiseFloorDb {
            noiseFloorDb = max(db, Self.floorLimitDb)
        } else {
            noiseFloorDb += (db - noiseFloorDb) * Self.riseRate
        }
        let above = db - noiseFloorDb - Self.startDb
        return min(max(above / Self.rangeDb, 0), 1)
    }
}
