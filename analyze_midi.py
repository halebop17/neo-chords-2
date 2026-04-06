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

MIDI_SOURCES = [
    (Path(__file__).parent / "Files" / "neo soul vol 1", "chords-neo-soul-a"),
    (Path(__file__).parent / "Files" / "neo soul vol 2", "chords-neo-soul-b"),
]
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


# ─── Build groove pool ──────────────────────────────────────────────────────

def build_groove_pool(progressions: list[dict]) -> tuple[list[dict], list[dict]]:
    """
    Extract rhythm templates from progressions.
    Returns (groove_pool, groove_groups).
    Each groove: {feel, density, pattern=[{onset,duration},...], count, source_name}
    Each group:  {feel, indices=[...]} — indices into groove_pool.
    """
    SIXTEENTH = 0.0625  # 1/16 note in beats

    def quantize(onset: float) -> float:
        return round(onset / SIXTEENTH) * SIXTEENTH

    def pattern_key(chords: list[dict]) -> tuple:
        return tuple(quantize(c["onset"]) for c in chords)

    def syncopation_score(chords: list[dict], bar_len: float) -> float:
        """Fraction of onsets NOT landing within 0.1 beats of any integer beat."""
        off_beat = 0
        for c in chords:
            rel = c["onset"] % bar_len
            nearest_beat = round(rel)
            if abs(rel - nearest_beat) > 0.1:
                off_beat += 1
        return off_beat / len(chords) if chords else 0.0

    def feel_label(synco: float) -> str:
        if synco < 0.25:
            return "Straight"
        elif synco < 0.6:
            return "Moderate"
        else:
            return "Syncopated"

    seen: dict[tuple, dict] = {}  # pattern_key -> groove entry

    for prog in progressions:
        chords = prog["chords"]
        if not chords:
            continue
        time_sig = prog.get("time_sig", [4, 4])
        bar_len  = float(time_sig[0])  # beats per bar

        # Total bars (approximate)
        total_dur  = sum(c["duration"] for c in chords)
        total_bars = max(total_dur / bar_len, 1.0)
        density    = round(len(chords) / total_bars, 2)

        synco = syncopation_score(chords, bar_len)
        feel  = feel_label(synco)

        # Build absolute pattern (onset/duration per chord slot)
        pattern = [{"onset": round(c["onset"], 3),
                    "duration": round(c["duration"], 3)} for c in chords]

        key = pattern_key(chords)
        if key not in seen:
            seen[key] = {
                "feel":    feel,
                "density": density,
                "pattern": pattern,
                "count":   1,
                "source":  prog["name"],
            }
        else:
            seen[key]["count"] += 1

    groove_pool = sorted(seen.values(), key=lambda g: (g["feel"], g["density"]))

    # Build groups in fixed order
    FEEL_ORDER = ["Straight", "Moderate", "Syncopated"]
    groups_map: dict[str, list[int]] = {f: [] for f in FEEL_ORDER}
    for i, g in enumerate(groove_pool):
        feel = g["feel"]
        if feel in groups_map:
            groups_map[feel].append(i + 1)  # 1-based for Lua

    groove_groups = []
    for feel in FEEL_ORDER:
        indices = groups_map[feel]
        if indices:
            groove_groups.append({"feel": feel, "indices": indices})

    return groove_pool, groove_groups


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


def write_lua(progressions: list[dict], chord_pool: list[dict],
              groove_pool: list[dict], groove_groups: list[dict],
              out_path: Path):
    lines = []
    lines.append("-- Neo Chords 2 — Chord Database")
    lines.append(f"-- Total progressions: {len(progressions)}")
    lines.append(f"-- Total unique chords: {len(chord_pool)}")
    lines.append(f"-- Total unique grooves: {len(groove_pool)}")
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

    # Groove pool
    lines.append("  groove_pool = {")
    for g in groove_pool:
        pattern_str = "{" + ", ".join(
            f"{{onset = {s['onset']}, duration = {s['duration']}}}"
            for s in g["pattern"]
        ) + "}"
        lines.append(
            f'    {{feel = "{g["feel"]}", density = {g["density"]}, '
            f'count = {g["count"]}, pattern = {pattern_str}}},')
    lines.append("  },")
    lines.append("")

    # Groove groups
    lines.append("  groove_groups = {")
    for grp in groove_groups:
        idx_str = "{" + ", ".join(str(i) for i in grp["indices"]) + "}"
        lines.append(f'    {{feel = "{grp["feel"]}", indices = {idx_str}}},')
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
    all_progressions = []
    vol_chords: dict = {}  # prefix -> set of chord note tuples

    for folder, prefix in MIDI_SOURCES:
        mid_files = sorted(folder.glob("*.mid"))
        print(f"\nFound {len(mid_files)} MIDI files in:\n  {folder}\n")

        progs = []
        for i, path in enumerate(mid_files, 1):
            print(f"Parsing {path.name}...")
            result = parse_midi_file(path)
            if result:
                result["name"] = f"{prefix}-{i:03d}"
                print(f"  → {len(result['chords'])} chords, {result['bpm']} BPM")
                progs.append(result)

        print(f"Successfully parsed {len(progs)} / {len(mid_files)} files")
        vol_chords[prefix] = {tuple(c["notes"]) for p in progs for c in p["chords"]}
        all_progressions.extend(progs)

    # Cross-volume duplicate analysis
    prefixes = list(vol_chords.keys())
    if len(prefixes) >= 2:
        v1 = vol_chords[prefixes[0]]
        v2 = vol_chords[prefixes[1]]
        shared    = v1 & v2
        new_in_v2 = v2 - v1
        print(f"\n--- Cross-volume analysis ---")
        print(f"Vol 1 unique chord voicings : {len(v1)}")
        print(f"Vol 2 unique chord voicings : {len(v2)}")
        print(f"Shared (duplicate) voicings : {len(shared)}")
        print(f"New voicings in Vol 2       : {len(new_in_v2)}")

    chord_pool = build_chord_pool(all_progressions)
    print(f"\nTotal merged chord pool     : {len(chord_pool)}")

    groove_pool, groove_groups = build_groove_pool(all_progressions)
    print(f"Unique groove patterns: {len(groove_pool)}")
    for grp in groove_groups:
        print(f"  {grp['feel']}: {len(grp['indices'])} patterns")

    write_lua(all_progressions, chord_pool, groove_pool, groove_groups, OUTPUT_LUA)

    json_path = OUTPUT_LUA.with_suffix(".json")
    with open(json_path, "w") as f:
        json.dump({"progressions": all_progressions, "chord_pool": chord_pool,
                   "groove_pool": groove_pool, "groove_groups": groove_groups}, f, indent=2)
    print(f"Wrote: {json_path}")


if __name__ == "__main__":
    main()
