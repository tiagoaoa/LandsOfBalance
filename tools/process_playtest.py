#!/usr/bin/env python3
"""Playtest session post-processor (runs on the DEV MACHINE).

The phone is a dumb black box: it records the tester's microphone in
60-second WAV chunks plus a 1 Hz telemetry heartbeat, all on one session
timeline (see autoload/debug_recorder.gd). This tool does everything else:

  1. --pull        grab the newest session off the connected phone (adb
                   run-as tar of user://debug) into playtests/
  2. transcribe    every mic chunk with faster-whisper (word timestamps);
                   chunk filename offset + in-chunk time = session T+
  3. detect notes  utterances containing "note ..." (the tester's spoken
                   protocol: "note: the boss teleported")
  4. sync + report playtests/<session>/issues.md — each note with its
                   transcript, session timestamp and the surrounding
                   heartbeat telemetry, ready to be worked as issues

Usage:
  tools/process_playtest.py --pull            # fetch newest session, process it
  tools/process_playtest.py <session_dir>     # process an already-pulled dir
Options:
  --model MODEL     whisper model (default: base; small/medium for accuracy)
  --full-transcript also dump the entire transcript, not just notes

Requires: ~/.venvs/playtest with faster-whisper, adb for --pull.
"""

import argparse
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ADB = os.path.expanduser("~/Android/Sdk/platform-tools/adb")
PKG = "com.tpgame.douglassthekeeper"
REPO = Path(__file__).resolve().parent.parent
OUT_ROOT = REPO / "playtests"
NOTE_RE = re.compile(r"\bnote[e]?[,:\s]", re.IGNORECASE)
CONTEXT_SECONDS = 8.0


def pull_sessions() -> Path:
    """Fetch user://debug from the phone; return the newest session dir."""
    OUT_ROOT.mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(suffix=".tar", delete=False) as tf:
        tar_path = Path(tf.name)
    cmd = [ADB, "shell", f"run-as {PKG} sh -c 'cd files && tar cf - debug'"]
    print("pulling sessions from phone…")
    with open(tar_path, "wb") as out:
        subprocess.run(cmd, stdout=out, check=True)
    with tarfile.open(tar_path) as tar:
        tar.extractall(OUT_ROOT)
    tar_path.unlink()
    sessions = sorted((OUT_ROOT / "debug").glob("session_*"))
    if not sessions:
        sys.exit("no sessions found on device")
    for s in sessions:
        dest = OUT_ROOT / s.name
        if not dest.exists():
            s.rename(dest)
    newest = sorted(OUT_ROOT.glob("session_*"))[-1]
    print(f"newest session: {newest}")
    return newest


def load_heartbeats(session: Path) -> list:
    """[(t_seconds, line)] from session_log.txt."""
    beats = []
    log = session / "session_log.txt"
    if not log.exists():
        print("WARNING: no session_log.txt")
        return beats
    for line in log.read_text(errors="replace").splitlines():
        m = re.match(r"T\+(\d+\.\d+)\s+(.*)", line)
        if m:
            beats.append((float(m.group(1)), m.group(2)))
    return beats


def transcribe(session: Path, model_name: str) -> list:
    """[(session_t, text)] utterance segments across all mic chunks."""
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        sys.exit("faster-whisper missing — run with ~/.venvs/playtest/bin/python")
    chunks = sorted(session.glob("mic_T+*.wav"))
    if not chunks:
        sys.exit(f"no mic chunks in {session}")
    print(f"transcribing {len(chunks)} chunk(s) with '{model_name}'…")
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    utterances = []
    for chunk in chunks:
        m = re.search(r"mic_T\+(\d+)s", chunk.name)
        offset = float(m.group(1)) if m else 0.0
        segments, _info = model.transcribe(str(chunk), language="en",
                vad_filter=True, word_timestamps=False)
        for seg in segments:
            text = seg.text.strip()
            if text:
                utterances.append((offset + seg.start, text))
                print(f"  T+{offset + seg.start:7.1f}  {text}")
    return utterances


def context_for(beats: list, t: float) -> list:
    return [f"T+{bt:07.2f}  {line}" for bt, line in beats
            if abs(bt - t) <= CONTEXT_SECONDS]


def write_report(session: Path, utterances: list, beats: list,
        full_transcript: bool) -> Path:
    notes = [(t, txt) for t, txt in utterances if NOTE_RE.search(txt)]
    report = session / "issues.md"
    with open(report, "w") as f:
        f.write(f"# Playtest issues — {session.name}\n\n")
        header = [line for _t, line in beats[:3]]
        for h in header:
            f.write(f"> {h}\n")
        f.write(f"\n{len(notes)} spoken note(s) detected out of "
                f"{len(utterances)} utterance(s).\n\n")
        if not notes:
            f.write("_No 'note:' utterances found — check the full "
                    "transcript below or re-run with a bigger --model._\n\n")
        for i, (t, txt) in enumerate(notes, 1):
            f.write(f"## Issue {i} — T+{t:.0f}s\n\n")
            f.write(f"**Spoken:** {txt}\n\n")
            f.write("**Telemetry (±%ds):**\n```\n" % int(CONTEXT_SECONDS))
            ctx = context_for(beats, t)
            f.write("\n".join(ctx) if ctx else "(no heartbeat lines in range)")
            f.write("\n```\n\n")
        if full_transcript or not notes:
            f.write("## Full transcript\n\n```\n")
            for t, txt in utterances:
                f.write(f"T+{t:7.1f}  {txt}\n")
            f.write("```\n")
    print(f"report: {report}")
    return report


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("session", nargs="?", help="session directory")
    ap.add_argument("--pull", action="store_true")
    ap.add_argument("--model", default="base")
    ap.add_argument("--full-transcript", action="store_true")
    args = ap.parse_args()

    if args.pull:
        session = pull_sessions()
    elif args.session:
        session = Path(args.session)
    else:
        candidates = sorted(OUT_ROOT.glob("session_*"))
        if not candidates:
            sys.exit("no local sessions; use --pull")
        session = candidates[-1]
        print(f"processing newest local session: {session}")

    beats = load_heartbeats(session)
    utterances = transcribe(session, args.model)
    write_report(session, utterances, beats, args.full_transcript)


if __name__ == "__main__":
    main()
