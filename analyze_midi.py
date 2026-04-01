#!/usr/bin/env python3
"""
MIDI chord analyzer for neo-chords-2.
Parses MIDI files from a folder, extracts chord progressions,
and outputs a Lua database file to embed in the Renoise plugin.
"""

import os
import sys
import json
from pathlib import Path
from collections import defaultdict

try:
    import mido
except ImportError:
    print("ERROR: mido not installed. Run: pip3 install mido")
    sys.exit(1)

# ─── Configuration ───────────────────────────────────────────────────────────

MIDI_FOLDER = Path(__file__).parent / "Files" / "lee chords neo soul vol 1"
OUTPUT_LUA  = Path(__file__).parent / "chord_db.lua"

# Notes that start within this many ticks of each other are grouped as one chord.
# Will be scaled based on PPQ (default assumes 480 PPQ → 1/16 note = 30 ticks window)
CHORD_WINDOW_RATIO = 1 / 16   # 1/16th note as fraction of a quarter note

# Minimum number of simultaneous notes to count as a chord (ignore single melody notes)
MIN_CHORD_NOTES = 2

# ─── Note/Chord naming ───────────────────────────────────────────────────────

NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

_CHORD_TYPES_RAW = {
    # Triads
    (0, 4, 7):           "maj",
    (0, 3, 7):           "m",
    (0, 4, 8):           "aug",
    (0, 3, 6):           "dim",
    (0, 2, 7):           "sus2",
    (0, 5, 7):           "sus4",
    # Seventh chords
    (0, 4, 7, 11):       "maj7",
    (0, 3, 7, 10):       "m7",
    (0, 4, 7, 10):       "7",
    (0, 3, 6, 10):       "m7b5",
    (0, 3, 6, 9):        "dim7",
    (0, 4, 8, 10):       "aug7",
    (0, 4, 7, 9):        "6",
    (0, 3, 7, 9):        "m6",
    (0, 4, 11):          "maj7(no5)",
    (0, 3, 10):          "m7(no5)",
    # Ninths
    (0, 2, 4, 7, 11):    "maj9",
    (0, 2, 3, 7, 10):    "m9",
    (0, 2, 4, 7, 10):    "9",
    (0, 2, 4, 7):        "add9",
    (0, 2, 3, 7):        "madd9",
    # Sixths/Ninths
    (0, 2, 4, 7, 9):     "6/9",
    (0, 2, 3, 7, 9):     "m6/9",
    # Elevenths
    (0, 2, 4, 5, 7, 10): "11",
    (0, 2, 3, 5, 7, 10): "m11",
    (0, 3, 5, 7, 10):    "m11(no9)",
    # Thirteenths
    (0, 2, 4, 7, 9, 10): "13",
    (0, 4, 7, 9, 10):    "13(no9)",
    # Alterations
    (0, 3, 4, 7, 10):    "7#9",     # Hendrix chord
    (0, 4, 6, 7, 11):    "maj7#11", # Lydian chord
    (0, 4, 6, 7, 10):    "7#11",
    (0, 4, 6, 10):       "7#11(no5)",
    (0, 3, 7, 11):       "mmaj7",
    (0, 2, 3, 7, 11):    "mmaj9",
    # Neo-soul common voicings
    (0, 2, 5, 7, 10):    "m11(no3)",  # quartal voicing
    (0, 2, 5, 9):        "sus2add6",
    (0, 3, 5, 10):       "m7sus4(no5)",
    (0, 5, 10):          "7sus4(no5)",
    (0, 2, 5, 7):        "sus2sus4",
}
# Normalize all keys to sorted tuples so lookup works regardless of ordering
CHORD_TYPES = {tuple(sorted(k)): v for k, v in _CHORD_TYPES_RAW.items()}


def label_chord(notes: list[int]) -> str:
    """Return a chord label like 'Cm7' or 'Fmaj9' for a list of MIDI notes."""
    if not notes:
        return "?"
    pitch_classes = sorted(set(n % 12 for n in notes))

    # Try every note as potential root
    best_label = None
    best_score = -1

    for root_pc in pitch_classes:
        intervals = tuple(sorted(set((pc - root_pc) % 12 for pc in pitch_classes)))
        if intervals in CHORD_TYPES:
            score = len(intervals)
            if score > best_score:
                best_score = score
                best_label = NOTE_NAMES[root_pc] + CHORD_TYPES[intervals]

    if best_label:
        return best_label

    # Fallback: just list pitch classes from lowest note
    root = notes[0] % 12
    return NOTE_NAMES[root] + "?"


# ─── MIDI parsing ────────────────────────────────────────────────────────────

def parse_midi_file(path: Path) -> dict | None:
    """Parse one MIDI file and return progression data, or None on error."""
    try:
        mid = mido.MidiFile(str(path))
    except Exception as e:
        print(f"  [SKIP] {path.name}: {e}")
        return None

    ppq = mid.ticks_per_beat
    chord_window = int(ppq * CHORD_WINDOW_RATIO)

    # Collect tempo (use first tempo change, default 120 BPM)
    tempo_us = 500000  # 120 BPM in microseconds per beat
    time_sig_num = 4
    time_sig_den = 4

    # Merge all tracks into one timeline of (abs_tick, msg) events
    events = []
    for track in mid.tracks:
        abs_tick = 0
        for msg in track:
            abs_tick += msg.time
            events.append((abs_tick, msg))

    events.sort(key=lambda e: e[0])

    # Extract tempo and time sig from meta messages
    for _, msg in events:
        if msg.type == "set_tempo":
            tempo_us = msg.tempo
        elif msg.type == "time_signature":
            time_sig_num = msg.numerator
            time_sig_den = msg.denominator

    bpm = round(60_000_000 / tempo_us, 1)

    # Build note event list: (abs_tick_on, abs_tick_off, pitch, velocity)
    active_notes = {}  # (channel, pitch) → abs_tick_on, velocity
    note_events = []

    for abs_tick, msg in events:
        if msg.type == "note_on" and msg.velocity > 0:
            active_notes[(msg.channel, msg.note)] = (abs_tick, msg.velocity)
        elif msg.type == "note_off" or (msg.type == "note_on" and msg.velocity == 0):
            key = (msg.channel, msg.note)
            if key in active_notes:
                on_tick, vel = active_notes.pop(key)
                note_events.append((on_tick, abs_tick, msg.note, vel))

    # Close any still-open notes at end of file
    for (ch, pitch), (on_tick, vel) in active_notes.items():
        note_events.append((on_tick, on_tick + ppq, pitch, vel))

    if not note_events:
        print(f"  [SKIP] {path.name}: no note events")
        return None

    # Group notes into chords by onset proximity
    note_events.sort(key=lambda e: e[0])

    chords_raw = []  # list of (onset_tick, [notes], off_tick)
    current_onset = None
    current_notes = []
    current_off = 0

    for on_tick, off_tick, pitch, vel in note_events:
        if current_onset is None or (on_tick - current_onset) > chord_window:
            if current_notes and len(current_notes) >= MIN_CHORD_NOTES:
                chords_raw.append((current_onset, sorted(current_notes), current_off))
            current_onset = on_tick
            current_notes = [pitch]
            current_off = off_tick
        else:
            current_notes.append(pitch)
            current_off = max(current_off, off_tick)

    if current_notes and len(current_notes) >= MIN_CHORD_NOTES:
        chords_raw.append((current_onset, sorted(current_notes), current_off))

    if not chords_raw:
        print(f"  [SKIP] {path.name}: no chords found (all single notes?)")
        return None

    # Convert tick positions to beats
    chords_out = []
    for i, (onset_tick, notes, off_tick) in enumerate(chords_raw):
        onset_beats = onset_tick / ppq
        # Duration = time until next chord onset (or note-off if last)
        if i + 1 < len(chords_raw):
            next_onset_tick = chords_raw[i + 1][0]
            dur_beats = (next_onset_tick - onset_tick) / ppq
        else:
            dur_beats = (off_tick - onset_tick) / ppq

        dur_beats = max(round(dur_beats * 4) / 4, 0.25)  # quantize to 1/16, min 1/4

        chords_out.append({
            "notes":    notes,
            "onset":    round(onset_beats, 3),
            "duration": round(dur_beats, 3),
            "label":    label_chord(notes),
        })

    return {
        "name":     path.stem,
        "bpm":      bpm,
        "time_sig": [time_sig_num, time_sig_den],
        "chords":   chords_out,
    }


# ─── Build chord pool ────────────────────────────────────────────────────────

def build_chord_pool(progressions: list[dict]) -> list[dict]:
    """Deduplicate chords across all progressions into a pool."""
    seen = {}  # frozenset(notes) → {label, count, notes}
    for prog in progressions:
        for chord in prog["chords"]:
            key = tuple(chord["notes"])
            if key not in seen:
                seen[key] = {"notes": list(key), "label": chord["label"], "count": 0}
            seen[key]["count"] += 1

    pool = sorted(seen.values(), key=lambda c: -c["count"])
    return pool


# ─── Lua output ──────────────────────────────────────────────────────────────

def lua_value(v, indent=0) -> str:
    pad = "  " * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        if all(isinstance(x, (int, float)) for x in v):
            return "{" + ", ".join(str(x) for x in v) + "}"
        lines = ["{\n"]
        for x in v:
            lines.append(pad + "  " + lua_value(x, indent + 1) + ",\n")
        lines.append(pad + "}")
        return "".join(lines)
    if isinstance(v, dict):
        lines = ["{\n"]
        for k, val in v.items():
            lines.append(pad + f"  {k} = {lua_value(val, indent + 1)},\n")
        lines.append(pad + "}")
        return "".join(lines)
    return str(v)


def write_lua(progressions: list[dict], chord_pool: list[dict], out_path: Path):
    lines = []
    lines.append("-- Neo Chords 2 — Chord Database")
    lines.append("-- Generated from: lee chords neo soul vol 1")
    lines.append(f"-- Total progressions: {len(progressions)}")
    lines.append(f"-- Total unique chords: {len(chord_pool)}")
    lines.append("")
    lines.append("CHORD_DB = {")
    lines.append("  version = 1,")
    lines.append("")

    # Progressions
    lines.append("  progressions = {")
    for i, prog in enumerate(progressions, 1):
        lines.append(f"    -- [{i}] {prog['name']}")
        lines.append("    {")
        lines.append(f'      name = "{prog["name"]}",')
        lines.append(f'      bpm = {prog["bpm"]},')
        lines.append(f'      time_sig = {{{prog["time_sig"][0]}, {prog["time_sig"][1]}}},')
        lines.append("      chords = {")
        for chord in prog["chords"]:
            notes_str = "{" + ", ".join(str(n) for n in chord["notes"]) + "}"
            lines.append(
                f'        {{notes = {notes_str}, onset = {chord["onset"]}, '
                f'duration = {chord["duration"]}, label = "{chord["label"]}"}},'
            )
        lines.append("      },")
        lines.append("    },")
    lines.append("  },")
    lines.append("")

    # Chord pool
    lines.append("  chord_pool = {")
    for chord in chord_pool:
        notes_str = "{" + ", ".join(str(n) for n in chord["notes"]) + "}"
        lines.append(
            f'    {{notes = {notes_str}, label = "{chord["label"]}", count = {chord["count"]}}},'
        )
    lines.append("  },")
    lines.append("")
    lines.append("}")
    lines.append("")
    lines.append("return CHORD_DB")
    lines.append("")

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nWrote: {out_path}")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    mid_files = sorted(MIDI_FOLDER.glob("*.mid"))
    print(f"Found {len(mid_files)} MIDI files in:\n  {MIDI_FOLDER}\n")

    progressions = []
    for path in mid_files:
        print(f"Parsing {path.name}...")
        result = parse_midi_file(path)
        if result:
            print(f"  → {len(result['chords'])} chords, {result['bpm']} BPM")
            progressions.append(result)

    print(f"\nSuccessfully parsed {len(progressions)} / {len(mid_files)} files")

    chord_pool = build_chord_pool(progressions)
    print(f"Unique chord voicings in pool: {len(chord_pool)}")

    write_lua(progressions, chord_pool, OUTPUT_LUA)

    # Also write a JSON summary for inspection
    json_path = OUTPUT_LUA.with_suffix(".json")
    with open(json_path, "w") as f:
        json.dump({"progressions": progressions, "chord_pool": chord_pool}, f, indent=2)
    print(f"Wrote: {json_path}")


if __name__ == "__main__":
    main()
