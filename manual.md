# Neo Chords 2 — User Manual

Neo Chords 2 is a Renoise tool for generating and writing neo-soul chord progressions into instrument phrases. It works from a baked database of 100 real MIDI chord progressions, analysed and embedded into the plugin.

---

## Table of Contents

- [Neo Chords 2 — User Manual](#neo-chords-2--user-manual)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Installation](#installation)
  - [Workflow at a Glance](#workflow-at-a-glance)
  - [Browse Originals Mode](#browse-originals-mode)
    - [Root Key dropdown](#root-key-dropdown)
    - [Progression dropdown](#progression-dropdown)
    - [Load Progression button](#load-progression-button)
  - [Randomize Mode](#randomize-mode)
    - [Recombine (weighted)](#recombine-weighted)
    - [Shuffle](#shuffle)
  - [Staged Progression](#staged-progression)
  - [Transpose](#transpose)
  - [Humanize](#humanize)
    - [Timing](#timing)
    - [Velocity](#velocity)
    - [Feel](#feel)
  - [Play Mode](#play-mode)
    - [Chord](#chord)
    - [Strum](#strum)
    - [Arp](#arp)
  - [Groove](#groove)
    - [Browse Grooves](#browse-grooves)
    - [Generate Random Groove](#generate-random-groove)
    - [Groove Patterns Reference](#groove-patterns-reference)
  - [Write to Phrase](#write-to-phrase)
  - [Tips and Combinations](#tips-and-combinations)
  - [Under the Hood](#under-the-hood)

---

## Overview

Neo Chords 2 gives you two ways to work:

- **Browse Originals** — pick from 100 real neo-soul progressions, grouped by root key.
- **Randomize** — generate new progressions by recombining or shuffling chords from the database.

Once you have a progression staged, you set how it should be written into the phrase: transposed, humanized, played as simultaneous chords, strummed, or arpeggiated. Then hit **Write to Phrase**.

---

## Installation

1. The tool folder is named `com.halebop.NeoChords2.xrnx`.
2. Copy it to your Renoise tools folder:
   `~/Library/Preferences/Renoise/V3.5.4/Scripts/Tools/`
3. In Renoise: **Tools → Reload All Tools** (or restart Renoise).
4. Open via **Tools → Neo Chords 2** or the keyboard shortcut in the tool menu.

---

## Workflow at a Glance

```
1. Choose mode: Browse or Randomize
2. Select / generate a progression → Load Progression (staged)
3. Set Transpose if needed
4. Set Humanize (Timing, Velocity, Feel)
5. Choose Play Mode (Chord / Strum / Arp) and configure it
6. Optionally: enable Groove and select or randomize a pattern
7. Click Write to Phrase
```

Each write creates a **new phrase** in the selected instrument. You can write the same staged progression multiple times with different settings to build up variations.

---

## Browse Originals Mode

Displays all 100 progressions from the database, grouped by the root note of their first chord.

### Root Key dropdown

Selects the group. Groups are ordered chromatically: C, C#, D, Eb, E, F, F#, G, Ab, A, Bb, B. Each group shows how many progressions it contains, e.g. `Root: Eb (8)`.

### Progression dropdown

Lists the progressions within the selected group. Each entry shows the first four chord labels, e.g.:
`1.  Cmaj9  C#maj9  Em11(no9)  F#maj7#11`

### Load Progression button

Stages the selected progression. The **Staged Progression** display updates to show all eight chord labels in sequence.

---

## Randomize Mode

Generates a new 8-chord progression on the fly using one of two strategies.

### Recombine (weighted)

Picks 8 chords independently from the full chord pool. Chords that appear more frequently in the database are more likely to be picked. Each chord gets a 2-beat duration. This creates fresh progressions that still feel idiomatic to the source material.

### Shuffle

Picks one complete progression from the database at random, then shuffles the order of its 8 chords. The original chord voicings are preserved; only the sequence changes.

Press the **Randomize** button to generate and stage a result. Press it again to get a different one.

---

## Staged Progression

The **Staged Progression** display (below the Browse/Randomize controls) always shows the currently staged progression as a chain of chord labels:

```
Cmaj9  →  C#maj9  →  Em11(no9)  →  F#maj7#11  →  ...
```

The staged progression persists until you load or generate a new one. You can write it to a phrase multiple times with different settings (different transpose, humanize, play mode) without re-staging.

---

## Transpose

Shifts every note in the staged progression by a number of semitones before writing.

- **Range:** −24 to +24 semitones
- **◄ / ►** buttons step down or up by 1 semitone
- **0** button resets to no transposition

Transpose is applied at write time. The staged progression itself is not modified, so you can write the same progression at multiple transpositions into separate phrases.

---

## Humanize

Humanize adds controlled imperfection to make written phrases feel more human and less mechanical. There are three independent parameters.

### Timing

Adds a **random per-note delay offset** within each chord. Each note gets a different amount of delay (measured in ticks, where 1 line = 256 ticks in Renoise).

- **0%** — all notes in a chord land exactly on the same tick (machine-tight).
- **100%** — notes can be displaced by up to 15 ticks randomly from each other.

In the phrase this appears as different values in the Delay column for each note within a chord. This simulates the natural imprecision of a live player hitting all keys at nearly — but not exactly — the same time.

> **Delay column:** Timing > 0% makes the Delay column visible in the written phrase.

### Velocity

Adds a **random per-note velocity scatter** around the taper values set in Chord mode.

- **0%** — every note gets exactly its calculated taper velocity (predictable).
- **100%** — each note's velocity is randomly offset by up to ±20 from its base value.

This simulates the natural variation in finger pressure when playing a chord. Visible in the Volume column of the phrase.

> Velocity humanize does **not** affect the Delay column — it only touches volume values.

### Feel

Adds a **global rush or drag bias** to the entire phrase. Unlike Timing (which is random per note), Feel applies the same shift to every note in the phrase.

- Each time you write, a direction is chosen at random: **rush** (shift all notes earlier) or **drag** (shift all notes later).
- **0%** — no global bias.
- **100%** — up to 8 ticks of uniform offset.

The result is a phrase that breathes as a unit — the whole thing sits slightly ahead of or behind the grid, like a player with a consistent natural tendency. Combine with Timing to get both global lean and per-note scatter.

> **◄ / ►** buttons on all three Humanize sliders step by 1%.  
> **0** button resets the parameter to 0%.

---

## Play Mode

Controls how the chord notes are arranged in the phrase. Three modes are available.

### Chord

All notes of a chord are written on the **same line** in separate note columns — a standard block chord. This is the default.

**Chord sub-controls:**

| Control | Description |
|---|---|
| **Root vel** | Velocity of the lowest (root) note. Default: 80. |
| **Top vel** | Velocity of the highest note. Default: 60. |
| **Length** | Note duration as a fraction of the chord's total duration. 25% / 50% / 75% / 100%. At less than 100%, a note-off is written at the end of the note to create separation between chords. |

The velocities taper linearly from Root vel (bottom note) to Top vel (top note). This gives chords a natural balance where the bass note punches through and inner/top voices sit back. Velocity humanize scatters each note's velocity around these base values.

### Strum

Notes in the chord are written on the **same line** but with increasing delay values per note — simulating a strummed guitar or harp-style roll.

**Strum sub-controls:**

| Control | Description |
|---|---|
| **Speed** | Ticks between each note in the strum. Range: 1–60. Lower = faster strum (tighter roll). Higher = slower strum (wider sweep). |
| **↑ Up / ↓ Down** | Direction of the strum. Up = lowest note first (root → top). Down = highest note first (top → root). |

Strum uses the Delay column to offset each note. Velocity taper (from Chord settings) still applies.

### Arp

Notes are spread across **separate lines** in the phrase, one note per step — a melodic arpeggio of the chord.

**Arp sub-controls:**

| Control | Description |
|---|---|
| **Step** | How many lines between each arp note: 1/16, 1/8, 1/4, 1/2. With LPB=8, 1/16 = 1 line, 1/8 = 2 lines, 1/4 = 4 lines, 1/2 = 8 lines. |
| **Pattern** | The order in which notes cycle (see table below). |

**Arp patterns:**

| Pattern | Description |
|---|---|
| **↑ Up** | Lowest note to highest, then repeat. |
| **↓ Down** | Highest note to lowest, then repeat. |
| **↑↓ Bounce** | Up then back down, skipping the top and bottom note on the turnaround (no repeated ends). |
| **↕ Shuffle** | Notes in random order, re-shuffled each time you write. |
| **⟳ PingPong** | Up then back down, repeating the top and bottom notes at the turnaround. |
| **⊛ Spiral** | Alternates lowest available / highest available, working inward: root, top, 2nd, 2nd-from-top, etc. |

In Arp mode only one note column is used. Velocity taper still applies per note in the sequence (col 1 voice).

---

## Groove

Groove controls *when* chord changes happen within the phrase. By default (Groove Off) each chord lands at its original timing from the source progression. When Groove is enabled, the staged progression's notes are kept exactly as-is but their onset positions and durations are remapped onto a rhythm template before writing.

The Groove section sits between Humanize and Play Mode. Enabling it reveals a Browse/Randomize mode switch.

### Browse Grooves

Two-level selector, just like Browse Originals for chords:

**Feel group dropdown** — three categories in order of rhythmic complexity:

| Feel | Description |
|---|---|
| **Straight (4)** | All chord hits land on integer beats, regular spacing. Predictable and tight. |
| **Moderate (4)** | Mix of on-beat and slightly pushed/uneven chords. Adds movement without losing clarity. |
| **Syncopated (4)** | Most chord changes fall between beats. Neo-soul / funky feel. |

**Groove preset dropdown** — lists the presets within the selected feel group by name. Selecting a preset immediately sets the active groove pattern.

### Generate Random Groove

Click **Generate Random Groove** to create a novel groove pattern algorithmically. The currently selected **Feel group** is used as a constraint — it defines the pool of valid beat positions the generator is allowed to pick from, so Straight generates tighter on-beat patterns and Syncopated generates more off-beat ones.

The result is not drawn from the 12 presets; it is a freshly generated pattern each time you click. Press it repeatedly to get different results within the same feel character. The generated pattern description is shown below the button.

### Groove Patterns Reference

All patterns span 16 beats (4 bars of 4/4). When a progression has more chord slots than a pattern, the pattern cycles from the beginning with the onset offset forward by one pattern length.

**Straight**

| Name | Description |
|---|---|
| **Block** | 4 chords, one per bar (4 beats each). Very sparse and open. |
| **Standard** | 8 chords, every half-bar (2 beats each). The original MIDI pack feel. |
| **Quick pairs** | 8 chords in pairs: two quick hits per bar with a gap after each pair. |
| **Long-short** | Alternating 3-beat / 1-beat pattern. Creates a lopsided driving feel. |

**Moderate**

| Name | Description |
|---|---|
| **End push** | Most chords land on the beat; the last chord of each half-bar is pushed 0.5 beats early. |
| **Light swing** | Every other chord shifted slightly forward, creating a subtle swing bounce. |
| **Half push** | Alternating on-beat / slightly-ahead pairs throughout the bar. |
| **Asymmetric** | Long-short-long rhythm: 3 beats, 1 beat, 4 beats, cycling. Only 6 slots — patterns cycle. |

**Syncopated**

| Name | Description |
|---|---|
| **Charleston** | Alternating short hit (1.5 beats) then long hold (2.5 beats). Classic neo-soul/jazz piano feel. |
| **Off-beat** | Every first chord of each pair lands a half-beat late (on the "and"). |
| **Neo push** | Chords anticipate each bar by a half-beat: long hold then a quick push into the next bar. |
| **Funk** | Dense, irregular — quick stabs with varying gaps. Rhythmically complex. |

> **Groove is a pre-pass**: it remaps onset/duration before the phrase is written. Transpose, Humanize, and Play Mode all apply on top of the groove-remapped timing. Humanize Timing and Feel add tick-level micro-offsets *within* each groove-established position — they don't move chords between beats, but they do layer human variation on top of wherever groove placed them. Strum and Arp work naturally within each groove slot.

---

## Write to Phrase

Clicking **Write to Phrase** creates a new phrase in the currently selected Renoise instrument using all the current settings.

- A new phrase is always created (never overwrites an existing one).
- The phrase is set to **loop**, **LPB = 8**, and the correct number of lines for the progression length.
- The phrase name is automatically set to `Neo Chords [n]`.
- The status bar shows a summary: `wrote 8 chords → phrase #3  |  tr +0  |  chord`

After writing, the progression **stays staged**. You can change Transpose, Humanize, or Play Mode and write again to add another phrase variation without re-selecting the progression.

---

## Tips and Combinations

**Layered variations from one progression:**
1. Load a progression.
2. Write it in Chord mode, Timing 0%, Velocity 0%.
3. Change to Strum, Speed 8, Timing 30%, Velocity 20%. Write again.
4. Two phrases from the same chords — one tight, one loose.

**Natural chord feel without timing smear:**
- Set Timing to 0%, Velocity to 25–40%, Feel to 20–40%.
- All notes land together but with different pressure and a slight global lean.

**Chord + Feel only — most natural block chord:**
- Timing 0%, Velocity 15–25%, Feel 20–50%.
- The phrase breathes in one direction each write — sometimes rushing, sometimes dragging.

**Arp from a Browse progression:**
- Browse to a progression with interesting voicings (dense chords work best).
- Set Arp mode, Step = 1/8, Pattern = Spiral.
- Transpose down an octave (−12) for a bass arp.

**Multiple root-key phrases for a track:**
- Stage a progression in C, write it.
- Change Transpose to +5. Write again.
- Now you have the same progression in C and F as separate looping phrases.

**Groove + Arp for melodic bass lines:**
- Stage a progression, enable Groove, pick "Charleston" (Syncopated).
- Switch Play Mode to Arp, Step = 1/8, Pattern = Up.
- Transpose −12. Write.
- The arp pattern cycles *within each groove slot*, giving a syncopated bass arp.

**Compare feels instantly:**
1. Load a progression, write it with Groove Off (Chord mode, no humanize).
2. Enable Groove → Syncopated → Charleston. Write again.
3. Enable Groove → Moderate → End push. Write again.
4. Three phrases, same chords, three different rhythmic characters.

---

## Under the Hood

**Database:** Built by analysing MIDI files using a Python script (`analyze_midi.py` + `mido`). The analysis extracts chord onsets, durations, notes, and labels. Output is baked into `chord_db.lua` and embedded in the tool.

- 100 progressions, each 8 chords  
- 81 unique chord voicings in the pool  
- Chord labels cover: maj7, maj9, maj9#11, m7, m9, m11, dom7, dom9, add9, sus2, sus4, 6/9, and neo-soul extensions (no9, #11, b9, etc.)

**LPB = 8:** All phrases use 8 Lines Per Beat, giving 1/32-note resolution (1 line = 1/32 note). Chord step sizes in Arp mode reference this grid. Groove onset values are in beats and are multiplied by LPB to get line positions.

**Groove engine:** 12 handcrafted patterns across three feel groups (Straight / Moderate / Syncopated). All patterns span 16 beats (4 bars). When the staged progression has more chord slots than the pattern, the pattern cycles with the onset shifted forward by one full pattern length. Feel categories are assigned by syncopation level: fraction of onsets not landing on or near integer beats.

**Phrase structure:**
- Lines per phrase = `(last chord onset + duration) × LPB`, clamped to 16–512.
- Note columns = number of notes in the widest chord, clamped to 2–12.
- Volume and Delay columns are added automatically as needed.

**Tick resolution:** Renoise delay column values are 0–255 per line. With LPB=8, one beat = 8 lines, and 1 line = 1/8-note worth of ticks. Feel and Timing humanize values are expressed internally in ticks (max 15 ticks scatter for Timing, max 8 ticks for Feel).
