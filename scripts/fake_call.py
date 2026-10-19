#!/usr/bin/env python3
"""Plays a scripted two-person call through the speakers and times cluely-local against it.

Default:    Them only. One afplay process, captured by audiotee (--them-pid) and muted while
            captured (--mute-them), so nothing is heard and the mic is off.
--speakers: both voices play out of the MacBook speakers through ffmpeg, and the built-in mic
            hears Me, and Them as echo, which is what the echo gate is for.

Each utterance's end time is known from how the tracks were built, so for every transcript
line this prints the seconds from end of speech (as played) to the line appearing.

Usage: scripts/fake_call.py [normal|fast] [--speakers] [extra cluely-local flags...]
Run from the repo root after `swift build -c release`.
"""
import os, subprocess, sys, tempfile, time, wave, re

RATE = 22050
LEAD_IN = 3.0          # silence before the first line, so capture is running
TAIL = 6.0             # wait after the last line for the last clips

SCRIPTS = {
    # (speaker, text, gap after in seconds)
    "normal": [
        ("Them", "Thanks for making time today. Can you walk me through how pricing works for a team of forty?", 2.5),
        ("Me", "Sure. It's twelve dollars a seat each month, billed yearly, so about five thousand eight hundred.", 2.5),
        ("Them", "That's more than we budgeted. Is there any discount if we sign for two years?", 2.5),
        ("Me", "We can usually do fifteen percent off for a two year term. I'd need to confirm with finance.", 2.5),
        ("Them", "Okay. And does that include single sign on, or is that an extra add on?", 2.5),
        ("Me", "Single sign on is included on the business plan, along with the audit log.", 2.5),
    ],
    "fast": [
        ("Them", "So what's the timeline?", 0.3),
        ("Me", "Six weeks.", 0.3),
        ("Them", "Six? Why not four?", 0.3),
        ("Me", "Security review takes two.", 0.3),
        ("Them", "Can you skip it?", 0.3),
        ("Me", "Not for enterprise.", 0.3),
        ("Them", "Fine, six weeks then.", 0.3),
        ("Me", "Great, I'll send the plan today.", 0.3),
    ],
}
VOICES = {"Them": "Samantha", "Me": "Daniel"}


SPEAKERS = "MacBook Pro Speakers"
MIC = "MacBook Pro Microphone"
GAIN = 3.0  # the built-in speakers are quiet next to a person talking in the room


def render(text, voice, path):
    """Returns the PCM with say's trailing silence trimmed, so utterance ends are when the voice stops."""
    subprocess.run(["say", "-v", voice, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", "-o", path, text], check=True)
    with wave.open(path) as w:
        audio = w.readframes(w.getnframes())
    samples = memoryview(audio).cast("h")
    last = max((i for i in range(len(samples)) if abs(samples[i]) > 300), default=len(samples) - 1)
    return audio[: (last + 1) * 2]


def speaker_index():
    out = subprocess.run(["ffmpeg", "-hide_banner", "-f", "lavfi", "-i", "anullsrc", "-t", "0.01",
                          "-f", "audiotoolbox", "-list_devices", "true", "-"], capture_output=True, text=True).stderr
    for line in out.splitlines():
        m = re.search(r"\[(\d+)\]\s+" + SPEAKERS, line)
        if m:
            return m[1]
    sys.exit(f"no output device named {SPEAKERS}")


def build(turns, workdir):
    tracks = {"Them": bytearray(), "Me": bytearray()}
    cursor, timeline = LEAD_IN, []
    for i, (speaker, text, gap) in enumerate(turns):
        audio = render(text, VOICES[speaker], os.path.join(workdir, f"{i}.wav"))
        duration = len(audio) / 2 / RATE
        for name, track in tracks.items():
            target = int(cursor * RATE) * 2
            track.extend(b"\0" * (target - len(track)))
            if name == speaker:
                track.extend(audio)
        timeline.append({"speaker": speaker, "text": text, "start": cursor, "end": cursor + duration})
        cursor += duration + gap
    paths = {}
    for name, track in tracks.items():
        track.extend(b"\0" * (int((cursor + 1) * RATE) * 2 - len(track)))
        paths[name] = os.path.join(workdir, f"{name}.wav")
        with wave.open(paths[name], "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(bytes(track))
    return timeline, paths, cursor


def words(text):
    return set(re.findall(r"[a-z]+", text.lower()))


def main():
    args = sys.argv[1:]
    name = args.pop(0) if args and not args[0].startswith("-") else "normal"
    speakers = "--speakers" in args
    extra = [a for a in args if a != "--speakers"]
    workdir = tempfile.mkdtemp(prefix="cluely-fake-call-")
    timeline, paths, length = build(SCRIPTS[name], workdir)

    # The clock starts as the players launch; the tracks open with 3 s of silence, so capture is
    # running before anyone speaks. (Pausing the players with SIGSTOP doesn't work: Core Audio keeps
    # playing what's already queued, which shifts the whole timeline.)
    index = speaker_index() if speakers else None
    t0 = time.time()
    if speakers:
        players = {s: subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", p, "-af", f"volume={GAIN}",
                                        "-f", "audiotoolbox", "-audio_device_index", index, "-"])
                   for s, p in paths.items()}
        mode = ["--mic-device", MIC]
    else:
        players = {"Them": subprocess.Popen(["afplay", paths["Them"]])}
        mode = ["--mute-them", "--no-mic"]
    app = subprocess.Popen([".build/release/cluely-local", "--them-pid", str(players["Them"].pid),
                            "--seconds", str(length + TAIL - (time.time() - t0)), *mode, *extra],
                           stdout=subprocess.PIPE, stderr=sys.stderr, text=True, bufsize=1)

    lines = []
    for raw in app.stdout:
        arrived = time.time()
        m = re.match(r"- \[[\d:]+\] (Me|Them): (.*)", raw.strip())
        if m:
            lines.append({"speaker": m[1], "text": m[2], "t": arrived - t0})
            print(f"{arrived - t0:6.2f}s  {raw.strip()}", flush=True)
    app.wait()

    for p in players.values():
        p.wait()
    print(f"\n{name} call{' (speakers)' if speakers else ''}, {len(timeline)} turns. Lag = line printed minus end of the utterance it finishes.")
    used = set()
    for line in lines:
        hits = [i for i, u in enumerate(timeline)
                if i not in used and u["speaker"] == line["speaker"] and u["end"] <= line["t"]
                and len(words(u["text"]) & words(line["text"])) >= max(1, len(words(u["text"])) // 2)]
        if not hits:
            print(f"  {line['speaker']:4}  no matching utterance (echo or mishearing?): {line['text']}")
            continue
        used.update(hits)
        end = max(timeline[i]["end"] for i in hits)
        print(f"  {line['speaker']:4}  lag {line['t'] - end:5.2f}s  covers turn(s) {[i + 1 for i in hits]}")
    expected = [i for i, u in enumerate(timeline) if speakers or u["speaker"] == "Them"]
    missing = [i + 1 for i in expected if i not in used]
    print(f"  turns with no line: {missing or 'none'}")


if __name__ == "__main__":
    main()
