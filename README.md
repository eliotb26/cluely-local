# cluely-local

A free, open-source meeting copilot for macOS, built after taking Cluely apart. It transcribes your call on your Mac as it happens. Press ⌘⏎ and Claude reads your screen and the last five minutes of the conversation, then tells you what to say.

Your microphone is "Me". Everything your Mac plays, which is the call, is "Them". Transcription runs locally with whisper.cpp. The app is about 1,170 lines of Swift.

## Quick start

```sh
git clone https://github.com/eliotb26/cluely-local.git && cd cluely-local
./scripts/setup.sh
swift run -c release cluely-local
```

Setup needs Homebrew. It installs whisper.cpp and ffmpeg, fetches the `audiotee` binary (checksum-pinned), downloads the 574 MB speech model into `models/` and builds. If [wispr-local](https://github.com/eliotb26/wispr-local) sits next to this folder, it links that model instead of downloading it again. Run from the repo folder, because that's where it looks for the model.

Join a call. Lines appear in the terminal and in `transcript.md`:

```
- [18:40:24] Them: So what's the timeline?
- [18:40:29] Me: Security review takes two.
```

Press ⌘⏎ at any point to ask "What should I say next?". To ask your own question, run this from a second terminal:

```sh
swift run -c release cluely-local ask "what did they say their budget was?"
```

The answer is printed, and it also appears in a small always-on-top window for 30 seconds. Ctrl+C stops listening.

## Permissions

The first time it runs, macOS asks your terminal app for:

- **Microphone**, to hear you (through ffmpeg).
- **System Audio Recording**, to hear the call (through audiotee and Core Audio taps, macOS 14.2 or later). It's under System Settings > Privacy & Security > Screen & System Audio Recording.
- **Screen Recording**, for the screenshot sent with each question.

The hotkey doesn't need Accessibility permission.

## How it works

`audiotee` taps system audio and streams 16 kHz PCM in 50 ms chunks, which is how Cluely runs it. ffmpeg does the same for the mic.

Each stream has its own voice activity detector, using Cluely's Silero settings: start at 0.3, end at 0.25, 800 ms kept from before speech, 1.4 s of quiet to end a clip, clips under 400 ms of speech dropped, and a 20 s hard cap. Silero needs an ONNX runtime, so this uses a small energy-based detector with the same timings instead: loudness above a tracked noise floor, mapped to a 0 to 1 score.

While Them is talking, the mic is muted for transcription so the call coming out of your speakers isn't written down as you. It reopens 300 ms after their voice stops. Cluely keeps the mic closed until their clip ends, which takes 1.4 s, and in a fast back-and-forth that cuts off the start of your reply.

Every finished clip becomes a WAV, `whisper-cli` transcribes it, and a line is appended to `transcript.md`. Clips go through whisper one at a time, and if they pile up they wait in a queue. Cluely drops a clip when four are already in flight. To get that behaviour, use `--drop-at 4`.

When you ask a question, `screencapture -x` grabs the screen, which is shrunk to 1,600 px. The prompt is laid out the way Cluely lays it out: `<screen_use>`, then `<audio_transcript>`, then your question. It goes to Claude Haiku through the [Claude Code](https://claude.com/claude-code) CLI on your existing plan. If `ANTHROPIC_API_KEY` is set, it calls the API directly, with the image attached.

The answer window is **not** hidden from screen sharing. Cluely hides its overlay with `setContentProtection`. This one leaves the default on purpose, so anyone you share your screen with can see it.

## Measured on an M4 Pro

These numbers come from real runs on 2026-10-17, macOS 26.3.1. The raw rows, with a label for each run, are in [docs/runs-m4-pro.csv](docs/runs-m4-pro.csv). Every clip and every ask appends its timings to `runs.csv`, but never what was said.

| | Result |
|---|---|
| Them: voice stops → line appears (stopwatch, 24 clips) | 2.43 to 3.33 s, median 2.75 s |
| Them: last speech frame → line appears (app's own clock, 24 clips) | 2.16 to 3.09 s, median 2.41 s |
| …of which is waiting for 1.4 s of quiet | 1.41 s |
| whisper per clip, 0.6 to 20 s of audio (39 live clips) | 0.75 to 1.64 s, median 0.95 s |
| whisper, first clip after launch (7 runs) | median 1.12 s |
| Ask → answer printed (5 asks) | 7.0 to 11.6 s, median 8.5 s |
| …of which is Claude | 6.6 to 11.4 s |
| Tokens per ask | about 57,000 in (mostly cached), 500 to 1,500 out |
| Cost per ask, as reported by the CLI | $0.0063 to $0.0067 |

How the numbers were measured:

- `scripts/fake_call.py` builds a scripted call with two `say` voices and plays it. Because the end of every line is known from how the audio was built, it times each transcript line against the moment the voice actually stopped. Those stopwatch times include `afplay` startup and audiotee's own delay, so they are an upper bound.
- `whisper-cli` starts fresh for every clip, so it loads the model every time. In one run that took 0.41 s of 1.03 s. "First clip after launch" is cold for cluely-local but not for macOS. The roughly 12 s GPU shader compile on the very first whisper run after installing wasn't measured again here.
- In a burst test, a 53 s file of 12 sentences was fed in faster than real time (`--file`), so all 12 clips arrived at once. All 12 were queued and transcribed, with up to 12 in flight, and the whole run took 10 s. With `--drop-at 4`, 8 of the 12 were dropped. On a live fast back-and-forth, at most 2 clips were ever in flight.

## Testing it without a call

```sh
swift build -c release
scripts/fake_call.py normal             # Them only: captured from one afplay and muted, so you hear nothing
scripts/fake_call.py fast --speakers    # both voices out loud, built-in mic hears "Me" and the echo
```

## Limitations

- **The mic hears the room.** Me is whatever the mic picks up. In testing, with both voices played from the laptop speakers in a room where people were talking, about the same loudness as the speakers, Me caught 3 of 4 turns in the fast script. In the slower one it caught 1 or 2 of 3, often partly garbled, and none cleanly until the playback was turned up 3×. The energy detector can't separate speakers from room noise; Silero wouldn't help much either when the background is also speech. With your own voice close to the mic, or a headset, this is much less of a problem. Without the echo gate, the mic picked up all of Them as one long "Me" clip.
- **The default mic might not be the one you're using.** If AirPods are the default input, the mic stream listens to them. Use `--mic-device "MacBook Pro Microphone"` to choose another.
- **Whisper invents words on near-silence.** Short clips sometimes come back as "Thank you." or "Excuse me." Lines with no words are dropped, but those aren't.
- **Asking is slow**, at 7 to 12 s. The CLI starts fresh each time and takes a second turn to open the screenshot. A direct API call, which happens when `ANTHROPIC_API_KEY` is set, saves that turn, but that path wasn't tested for these numbers.
- Speakers are told apart by source, not by voice, so everyone on the call is "Them".
- Tested on one machine, an M4 Pro, using synthetic `say` voices. Requires macOS 14.2 or later.

## Privacy

Audio never leaves your Mac. Clips are written to temporary WAVs, transcribed and deleted. The transcript stays in `transcript.md`.

When you ask, the screenshot and the last five minutes of transcript go to Claude. Nothing is sent until you ask.

## Development

```sh
swift build -c release
swift test
```

`Sources/CluelyLocalCore` holds the parts that can be tested without audio: VAD segmentation, the echo gate, Me/Them labelling, the clip queue, transcript parsing and prompt assembly. It has 30 tests. `Sources/cluely-local` is the app: audio processes, whisper and Claude calls, hotkey and window.

The tests use Swift Testing, which needs full Xcode. If `swift test` can't find it, prefix it with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Credits

System audio capture is [AudioTee](https://github.com/makeusabrew/audiotee) by makeusabrew (MIT), the same binary Cluely ships. Transcription is [whisper.cpp](https://github.com/ggml-org/whisper.cpp) running `ggml-large-v3-turbo-q5_0.bin`. Answers come from Claude Haiku. The VAD settings and prompt layout come from looking at Cluely 2.1.20. No Cluely code is used.

## License

MIT. See [LICENSE](LICENSE).

cluely-local is an independent project. It is not affiliated with or endorsed by Cluely, and Cluely is a trademark of its owner.
