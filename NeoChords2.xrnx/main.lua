--[[
  Neo Chords 2 — Renoise Tool
  Browse and randomize neo-soul chord progressions.
  Writes the result into the current instrument's phrase.
]]

-- ─── Load database ───────────────────────────────────────────────────────────

local DB = require("chord_db")

-- ─── Group progressions by root of first chord ───────────────────────────────

local ROOT_ORDER = {"C","C#","D","Eb","E","F","F#","G","Ab","A","Bb","B"}

local function chord_root(label)
  if not label or label:sub(-1) == "?" then
    -- try to get at least the letter
    if label and #label >= 1 then
      if #label >= 2 and (label:sub(2,2) == "b" or label:sub(2,2) == "#") then
        return label:sub(1,2)
      end
      return label:sub(1,1)
    end
    return "?"
  end
  if #label >= 2 and (label:sub(2,2) == "b" or label:sub(2,2) == "#") then
    return label:sub(1,2)
  end
  return label:sub(1,1)
end

-- Build group table at load time (stable across dialog rebuilds)
local groups = {}       -- list of {root, progressions=[...]}
local _group_map = {}   -- root -> index in groups

for _, prog in ipairs(DB.progressions) do
  local root = (#prog.chords > 0) and chord_root(prog.chords[1].label) or "?"
  if not _group_map[root] then
    groups[#groups + 1] = { root = root, progressions = {} }
    _group_map[root] = #groups
  end
  local g = groups[_group_map[root]]
  g.progressions[#g.progressions + 1] = prog
end

table.sort(groups, function(a, b)
  local ai, bi = 99, 99
  for i, r in ipairs(ROOT_ORDER) do
    if r == a.root then ai = i end
    if r == b.root then bi = i end
  end
  return ai < bi
end)

-- ─── State ───────────────────────────────────────────────────────────────────

local state = {
  mode              = 1,  -- 1=Browse, 2=Randomize
  group_idx         = 1,
  prog_in_group_idx = 1,
  rand_type         = 1,  -- 1=Recombine, 2=Shuffle
  transpose         = 0,
  -- Humanize
  humanize_timing   = 0,  -- 0-100: random delay scatter (%)
  humanize_vel      = 0,  -- 0-100: velocity scatter (%)
  humanize_feel     = 0,  -- 0-100: global player tendency bias (%)
  -- Chord mode
  chord_vel_top     = 80, -- velocity for lowest note (root)
  chord_vel_bot     = 60, -- velocity for highest note (top)
  chord_length      = 4,  -- note length index: 1=25% 2=50% 3=75% 4=100%
  -- Play mode
  play_mode         = 1,  -- 1=Chord, 2=Strum, 3=Arp
  strum_speed       = 40, -- ticks between notes
  strum_dir         = 1,  -- 1=up, 2=down
  arp_step          = 2,  -- index into ARP_STEPS
  arp_dir           = 1,  -- 1=Up 2=Down 3=Bounce 4=Shuffle 5=PingPong 6=Spiral
  -- Groove
  groove_enabled    = false,
  groove_feel_idx   = 1,
  groove_in_feel_idx= 1,
  groove_pattern    = nil,  -- active {onset,dur} pattern or nil
  groove_rand_desc  = "",   -- description of last generated pattern
  preview           = nil,
  preview_active    = false,   -- true while progression preview is playing
  preview_notes     = nil,     -- notes currently ringing (for stop)
  -- Build tab
  build_queue       = {},      -- list of {notes, label, duration_beats}
  build_filter_root = 1,       -- 1=All, 2=C, 3=C#, ...
  build_chord_idx   = 1,       -- selected chord in filtered pool
  build_chord_dur   = 2,       -- duration index into BUILD_DURATIONS
  dialog            = nil,
}

local ARP_STEPS        = { 1, 2, 4, 8 }
local ARP_STEP_LABELS  = { "1/16", "1/8", "1/4", "1/2" }
local CHORD_LENGTHS    = { 0.25, 0.5, 0.75, 1.0 }
local CHORD_LEN_LABELS = { "25%", "50%", "75%", "100%" }
local BUILD_DURATIONS  = { 1.0, 2.0, 4.0 }
local BUILD_DUR_LABELS = { "1 beat", "2 beats", "4 beats" }
local BUILD_ROOTS      = { "All","C","C#","D","Eb","E","F","F#","G","Ab","A","Bb","B" }
-- MIDI root note for each BUILD_ROOTS entry (index 1 = All = nil)
local BUILD_ROOT_MIDI  = { nil,48,49,50,51,52,53,54,55,56,57,58,59 }

-- ─── Groove Presets ──────────────────────────────────────────────────────────────────
-- Each pattern entry: {onset=<beats>, dur=<beats>}
-- Patterns cycle through staged chords. 4 bars @ 4/4 = 16 beats total.
local GROOVE_PRESETS = {
  -- ─ Straight: on-beat, predictable placement ─────────────────────────────
  { name="Block",       feel="Straight",
    pattern={{onset=0,dur=4},{onset=4,dur=4},{onset=8,dur=4},{onset=12,dur=4}} },
  { name="Standard",    feel="Straight",
    pattern={{onset=0,dur=2},{onset=2,dur=2},{onset=4,dur=2},{onset=6,dur=2},
             {onset=8,dur=2},{onset=10,dur=2},{onset=12,dur=2},{onset=14,dur=2}} },
  { name="Quick pairs", feel="Straight",
    pattern={{onset=0,dur=1},{onset=1,dur=1},{onset=4,dur=1},{onset=5,dur=1},
             {onset=8,dur=1},{onset=9,dur=1},{onset=12,dur=1},{onset=13,dur=1}} },
  { name="Long-short",  feel="Straight",
    pattern={{onset=0,dur=3},{onset=3,dur=1},{onset=4,dur=3},{onset=7,dur=1},
             {onset=8,dur=3},{onset=11,dur=1},{onset=12,dur=3},{onset=15,dur=1}} },
  -- ─ Moderate: some anticipation / uneven spacing ────────────────────────
  { name="End push",    feel="Moderate",
    pattern={{onset=0,dur=2},{onset=2,dur=2},{onset=4,dur=2},{onset=5.5,dur=2.5},
             {onset=8,dur=2},{onset=10,dur=2},{onset=12,dur=2},{onset=13.5,dur=2.5}} },
  { name="Light swing", feel="Moderate",
    pattern={{onset=0,dur=1.75},{onset=1.75,dur=2.25},{onset=4,dur=1.75},{onset=5.75,dur=2.25},
             {onset=8,dur=1.75},{onset=9.75,dur=2.25},{onset=12,dur=1.75},{onset=13.75,dur=2.25}} },
  { name="Half push",   feel="Moderate",
    pattern={{onset=0,dur=2},{onset=2.5,dur=1.5},{onset=4,dur=2},{onset=6.5,dur=1.5},
             {onset=8,dur=2},{onset=10.5,dur=1.5},{onset=12,dur=2},{onset=14.5,dur=1.5}} },
  { name="Asymmetric",  feel="Moderate",
    pattern={{onset=0,dur=3},{onset=3,dur=1},{onset=4,dur=4},
             {onset=8,dur=3},{onset=11,dur=1},{onset=12,dur=4}} },
  -- ─ Syncopated: mostly off-beat / pushed chords ────────────────────────
  { name="Charleston",  feel="Syncopated",
    pattern={{onset=0,dur=1.5},{onset=1.5,dur=2.5},{onset=4,dur=1.5},{onset=5.5,dur=2.5},
             {onset=8,dur=1.5},{onset=9.5,dur=2.5},{onset=12,dur=1.5},{onset=13.5,dur=2.5}} },
  { name="Off-beat",    feel="Syncopated",
    pattern={{onset=0.5,dur=1.5},{onset=2,dur=2},{onset=4.5,dur=1.5},{onset=6,dur=2},
             {onset=8.5,dur=1.5},{onset=10,dur=2},{onset=12.5,dur=1.5},{onset=14,dur=2}} },
  { name="Neo push",    feel="Syncopated",
    pattern={{onset=0,dur=3.5},{onset=3.5,dur=0.5},{onset=4,dur=3.5},{onset=7.5,dur=0.5},
             {onset=8,dur=3.5},{onset=11.5,dur=0.5},{onset=12,dur=3.5},{onset=15.5,dur=0.5}} },
  { name="Funk",        feel="Syncopated",
    pattern={{onset=0,dur=1.5},{onset=1.5,dur=1},{onset=3,dur=1},{onset=4,dur=1.5},
             {onset=5.5,dur=0.5},{onset=6,dur=2},{onset=8,dur=1.5},{onset=9.5,dur=2.5}} },
}

-- Build feel groups
local groove_groups   = {}
local _gfeel_order    = { "Straight", "Moderate", "Syncopated" }
local _gfeel_map      = {}
for _, feel in ipairs(_gfeel_order) do
  groove_groups[#groove_groups + 1] = { feel = feel, presets = {} }
  _gfeel_map[feel] = #groove_groups
end
for i, g in ipairs(GROOVE_PRESETS) do
  local grp = groove_groups[_gfeel_map[g.feel]]
  if grp then grp.presets[#grp.presets + 1] = i end
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function copy_chord(c)
  local n = {}
  for _, v in ipairs(c.notes) do n[#n + 1] = v end
  return { notes = n, onset = c.onset, duration = c.duration, label = c.label }
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

local function chords_to_string(chords)
  if not chords or #chords == 0 then return "(none)" end
  local SEP      = "  →  "
  local MAX_LINE = 62          -- display chars per line
  -- → is U+2192 = 3 UTF-8 bytes but displays as 1 char; correct for it
  local function dw(s)
    return #s - 2 * select(2, s:gsub("\xe2\x86\x92", ""))
  end
  local SEP_W  = dw(SEP)   -- = 5 display chars
  local result   = ""
  local line_len = 0
  for i, c in ipairs(chords) do
    local cw = #c.label   -- chord labels are ASCII
    if i == 1 then
      result   = c.label
      line_len = cw
    elseif line_len + SEP_W + cw > MAX_LINE then
      result   = result .. "\n" .. SEP .. c.label
      line_len = SEP_W + cw
    else
      result   = result .. SEP .. c.label
      line_len = line_len + SEP_W + cw
    end
  end
  return result
end

local function prog_items_for_group(g)
  local items = {}
  for i, p in ipairs(g.progressions) do
    local lbs = {}
    for j = 1, math.min(4, #p.chords) do lbs[#lbs + 1] = p.chords[j].label end
    items[#items + 1] = string.format("%d.  %s", i, table.concat(lbs, "  "))
  end
  return items
end

-- ─── Randomizer Logic ────────────────────────────────────────────────────────

local function randomize_recombine()
  local pool = DB.chord_pool
  if #pool == 0 then return nil end
  local total = 0
  for _, c in ipairs(pool) do total = total + c.count end
  local chords, beat = {}, 0
  for _ = 1, 8 do
    local r, cum = math.random() * total, 0
    local picked = pool[1]
    for _, c in ipairs(pool) do
      cum = cum + c.count
      if r <= cum then picked = c; break end
    end
    local ch = copy_chord(picked)
    ch.onset = beat; ch.duration = 2.0; beat = beat + 2.0
    chords[#chords + 1] = ch
  end
  return chords
end

local function randomize_shuffle()
  local prog = DB.progressions[math.random(#DB.progressions)]
  local chords = {}
  for _, c in ipairs(prog.chords) do chords[#chords + 1] = copy_chord(c) end
  shuffle(chords)
  local beat = 0
  for _, c in ipairs(chords) do c.onset = beat; beat = beat + c.duration end
  return chords
end

-- ─── Groove Generator ───────────────────────────────────────────────────────
-- Produces a novel constrained rhythm pattern from musical rules.
-- feel: "Straight", "Moderate", or "Syncopated"
local function generate_groove(feel)
  local GRID    = 0.25      -- 16th-note step
  local BARS    = 4         -- always 4 bars
  local BAR_LEN = 4.0       -- beats per bar
  local TOTAL   = BARS * BAR_LEN  -- 16 beats
  local MIN_DUR = 0.5       -- shortest chord (8th note)
  local MIN_GAP = 1.0       -- minimum beats between changes
  local MAX_CHORDS = 8

  -- Candidate onset pools by feel
  local pools = {
    Straight    = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 },
    Moderate    = { 0,0.5,1,1.5,2,2.5,3,3.5,4,4.5,5,5.5,6,6.5,7,7.5,
                    8,8.5,9,9.5,10,10.5,11,11.5,12,12.5,13,13.5,14,14.5,15,15.5 },
    Syncopated  = {},
  }
  -- Syncopated: all 16th positions, double-weight classic offbeats
  for i = 0, 63 do
    local b = i * GRID
    if b < TOTAL then
      pools.Syncopated[#pools.Syncopated + 1] = b
      local rel = b % BAR_LEN
      if rel == 0.5 or rel == 1.5 or rel == 2.5 or rel == 3.5 then
        pools.Syncopated[#pools.Syncopated + 1] = b
      end
    end
  end

  local pool = pools[feel] or pools.Straight

  local function valid_onset(onset, existing)
    for _, e in ipairs(existing) do
      if math.abs(onset - e) < MIN_GAP then return false end
    end
    return true
  end

  -- Single attempt: returns a valid pattern or nil
  local function try_generate()
    local onsets = { 0 }
    local shuffled = {}
    for _, v in ipairs(pool) do shuffled[#shuffled + 1] = v end
    for i = #shuffled, 2, -1 do
      local j = math.random(i)
      shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end
    for _, onset in ipairs(shuffled) do
      if onset > 0 and valid_onset(onset, onsets) then
        onsets[#onsets + 1] = onset
        if #onsets >= MAX_CHORDS then break end
      end
    end
    if #onsets < 2 then return nil end
    table.sort(onsets)

    -- Check: at least one onset near a bar boundary
    local has_bar_hit = false
    for _, o in ipairs(onsets) do
      if o % BAR_LEN < GRID * 1.5 then has_bar_hit = true; break end
    end
    if not has_bar_hit then return nil end

    -- Build slots
    local slots = {}
    local dur_set = {}
    for i, onset in ipairs(onsets) do
      local next_onset = (i < #onsets) and onsets[i + 1] or TOTAL
      local dur = math.max(MIN_DUR, next_onset - onset)
      dur = math.floor(dur / GRID + 0.5) * GRID
      slots[#slots + 1] = { onset = onset, dur = dur }
      dur_set[dur] = true
    end

    -- Check: at least 2 different duration values
    local n_durs = 0
    for _ in pairs(dur_set) do n_durs = n_durs + 1 end
    if n_durs < 2 then return nil end

    return slots
  end

  local pattern
  for _ = 1, 200 do
    pattern = try_generate()
    if pattern then break end
  end

  -- Fallback: Standard 8-chord pattern
  if not pattern then
    pattern = {}
    for i = 0, 7 do
      pattern[#pattern + 1] = { onset = i * 2, dur = 2 }
    end
  end
  return pattern
end

-- ─── Groove Applicator ──────────────────────────────────────────────────────────────────

local function apply_groove(chords, pattern)
  if not chords or not pattern or #pattern == 0 then return chords end
  local pat_len = pattern[#pattern].onset + pattern[#pattern].dur
  local result  = {}
  for i, chord in ipairs(chords) do
    local slot_idx = ((i - 1) % #pattern) + 1
    local cycle    = math.floor((i - 1) / #pattern)
    local slot     = pattern[slot_idx]
    local nc       = copy_chord(chord)
    nc.onset       = slot.onset + cycle * pat_len
    nc.duration    = slot.dur
    result[#result + 1] = nc
  end
  return result
end

-- ─── Chord / Progression Preview ────────────────────────────────────────────

-- Active timer handles for progression preview (one-shot chained timers)
local _preview_timers = {}

local function stop_chord_preview()
  local song = renoise.song()
  if state.preview_notes then
    local instr = song.selected_instrument_index
    local track = song.selected_track_index
    for _, note in ipairs(state.preview_notes) do
      song:trigger_instrument_note_off(instr, track, note)
    end
    state.preview_notes = nil
  end
end

local function play_chord_preview(notes)
  stop_chord_preview()
  local song  = renoise.song()
  local instr = song.selected_instrument_index
  local track = song.selected_track_index
  for _, note in ipairs(notes) do
    song:trigger_instrument_note_on(instr, track, note, 1.0)
  end
  state.preview_notes = notes
end

local function stop_progression_preview()
  for _, t in ipairs(_preview_timers) do
    if renoise.tool():has_timer(t) then
      renoise.tool():remove_timer(t)
    end
  end
  _preview_timers = {}
  stop_chord_preview()
  state.preview_active = false
end

local function play_progression_preview(chords)
  if not chords or #chords == 0 then return end
  stop_progression_preview()
  state.preview_active = true

  local bpm      = renoise.song().transport.bpm
  local ms_per_beat = 60000.0 / bpm

  -- Schedule each chord as a one-shot timer
  for i, chord in ipairs(chords) do
    local delay_ms = math.max(1, math.floor(chord.onset * ms_per_beat))
    local notes    = chord.notes
    -- Lua 5.1: capture by value via wrapper
    local function make_cb(n)
      local cb
      cb = function()
        play_chord_preview(n)
        if renoise.tool():has_timer(cb) then
          renoise.tool():remove_timer(cb)
        end
      end
      return cb
    end
    local cb = make_cb(notes)
    _preview_timers[#_preview_timers + 1] = cb
    renoise.tool():add_timer(cb, delay_ms)
  end

  -- Schedule stop after last chord ends
  local last = chords[#chords]
  local stop_ms = math.max(1, math.floor((last.onset + last.duration) * ms_per_beat))
  local function stop_cb()
    stop_progression_preview()
    if renoise.tool():has_timer(stop_cb) then
      renoise.tool():remove_timer(stop_cb)
    end
  end
  _preview_timers[#_preview_timers + 1] = stop_cb
  renoise.tool():add_timer(stop_cb, stop_ms)
end

-- ─── Build tab helpers ───────────────────────────────────────────────────────

local function filtered_chord_pool(root_idx)
  if root_idx <= 1 then return DB.chord_pool end
  local root_midi = BUILD_ROOT_MIDI[root_idx]  -- e.g. 48 for C
  local result = {}
  for _, c in ipairs(DB.chord_pool) do
    -- Check if any note in the chord has root_midi % 12 == root_midi % 12
    if c.notes[1] % 12 == root_midi % 12 then
      result[#result + 1] = c
    end
  end
  return result
end

local function build_pool_items(root_idx)
  local pool = filtered_chord_pool(root_idx)
  local items = {}
  for i, c in ipairs(pool) do
    items[#items + 1] = string.format("%d. %s", i, c.label)
  end
  if #items == 0 then items = { "(no chords for this root)" } end
  return items
end

local function build_queue_to_string()
  if not state.build_queue or #state.build_queue == 0 then
    return "(empty — add chords below)"
  end
  local SEP = "  →  "  -- →
  local MAX_LINE = 62
  local function dw(s)
    return #s - 2 * select(2, s:gsub("\xe2\x86\x92", ""))
  end
  local SEP_W = dw(SEP)
  local result, line_len = "", 0
  for i, item in ipairs(state.build_queue) do
    local cw = #item.label
    if i == 1 then
      result   = item.label
      line_len = cw
    elseif line_len + SEP_W + cw > MAX_LINE then
      result   = result .. "\n" .. SEP .. item.label
      line_len = SEP_W + cw
    else
      result   = result .. SEP .. item.label
      line_len = line_len + SEP_W + cw
    end
  end
  return result
end

-- ─── Phrase Writer ───────────────────────────────────────────────────────────

local LPB = 8

local function write_to_phrase(chords, st, hu_timing, hu_vel, hu_feel,
                               chord_vel_top, chord_vel_bot, chord_len_frac,
                               play_mode, strum_speed, strum_dir,
                               arp_step_lines, arp_dir)
  if not chords or #chords == 0 then
    renoise.app():show_warning("No progression staged. Browse or Randomize first.")
    return
  end
  local instrument = renoise.song().selected_instrument
  if not instrument then
    renoise.app():show_warning("No instrument selected.")
    return
  end

  local last       = chords[#chords]
  local total_lines= clamp(math.ceil((last.onset + last.duration) * LPB), 16, 512)
  local max_notes  = 0
  for _, c in ipairs(chords) do max_notes = math.max(max_notes, #c.notes) end
  max_notes = clamp(max_notes, 2, 12)

  local idx = #instrument.phrases + 1
  instrument:insert_phrase_at(idx)
  local phrase = instrument.phrases[idx]
  phrase.name                  = string.format("Neo Chords %d", idx)
  phrase.number_of_lines       = total_lines
  phrase.lpb                   = LPB
  phrase.looping               = true
  phrase.visible_note_columns  = max_notes
  phrase.volume_column_visible = true

  local ts          = clamp(st, -48, 48)
  local max_scatter = math.floor(hu_timing / 100 * 15)     -- max tick scatter
  local vel_scatter = math.floor(hu_vel    / 100 * 20)     -- max vel scatter ±
  local feel_bias   = math.floor(hu_feel   / 100 * 8)      -- global lean ticks
  local spd         = clamp(strum_speed, 1, 120)

  -- Per-phrase random feel direction (-1 drag, +1 rush)
  local feel_sign = (math.random(2) == 1) and 1 or -1

  -- Velocity taper helper: col 1 = root (loudest), last col = top (softest)
  local function note_velocity(col_idx, total_cols)
    if total_cols <= 1 then return chord_vel_top end
    local t = (col_idx - 1) / (total_cols - 1)  -- 0..1 from root to top
    local base = math.floor(chord_vel_top + t * (chord_vel_bot - chord_vel_top) + 0.5)
    if vel_scatter > 0 then
      base = base + math.random(-vel_scatter, vel_scatter)
    end
    return clamp(base, 1, 127)
  end

  -- Arp sequence builder
  local function build_arp_seq(sorted, dir)
    local n   = #sorted
    local seq = {}
    if dir == 1 then          -- Up
      for i = 1, n do seq[#seq+1] = sorted[i] end
    elseif dir == 2 then      -- Down
      for i = n, 1, -1 do seq[#seq+1] = sorted[i] end
    elseif dir == 3 then      -- Bounce (no repeat at ends)
      for i = 1, n do seq[#seq+1] = sorted[i] end
      for i = n-1, 2, -1 do seq[#seq+1] = sorted[i] end
    elseif dir == 4 then      -- Shuffle
      for i = 1, n do seq[#seq+1] = sorted[i] end
      shuffle(seq)
    elseif dir == 5 then      -- PingPong (repeat top+bottom)
      for i = 1, n do seq[#seq+1] = sorted[i] end
      for i = n, 1, -1 do seq[#seq+1] = sorted[i] end
    elseif dir == 6 then      -- Spiral (outside→inside)
      local lo, hi = 1, n
      while lo <= hi do
        seq[#seq+1] = sorted[lo];  lo = lo + 1
        if lo <= hi then
          seq[#seq+1] = sorted[hi]; hi = hi - 1
        end
      end
    end
    if #seq == 0 then seq = { sorted[1] or 60 } end
    return seq
  end

  phrase.delay_column_visible = (play_mode ~= 3) and
    (play_mode == 2 or max_scatter > 0 or feel_bias > 0)

  if play_mode == 3 then
    -- ── ARP ──────────────────────────────────────────────────────────────────
    phrase.visible_note_columns = 1
    local step = clamp(arp_step_lines, 1, 8)
    for _, chord in ipairs(chords) do
      local note_count  = math.min(#chord.notes, max_notes)
      local chord_lines = math.floor(chord.duration * LPB)
      local base_li     = clamp(math.floor(chord.onset * LPB) + 1, 1, total_lines)
      local sorted      = {}
      for i = 1, note_count do sorted[i] = chord.notes[i] end
      local seq   = build_arp_seq(sorted, arp_dir)
      local seq_i = 1
      local li    = base_li
      while li <= math.min(base_li + chord_lines - 1, total_lines) do
        local col = phrase.lines[li].note_columns[1]
        col.note_value   = clamp(seq[seq_i] + ts, 0, 119)
        col.volume_value = note_velocity(1, 1)
        seq_i = (seq_i % #seq) + 1
        li    = li + step
      end
    end

  else
    -- ── CHORD / STRUM ─────────────────────────────────────────────────────────
    for _, chord in ipairs(chords) do
      local note_count  = math.min(#chord.notes, max_notes)
      local chord_lines = math.max(1, math.floor(chord.duration * LPB * chord_len_frac))
      local base_li     = clamp(math.floor(chord.onset * LPB) + 1, 1, total_lines)

      -- Build note order
      local order = {}
      if play_mode == 2 and strum_dir == 2 then
        for i = note_count, 1, -1 do order[#order+1] = i end
      else
        for i = 1, note_count do order[#order+1] = i end
      end

      for step_i, ci in ipairs(order) do
        local delay = feel_sign * feel_bias
        if play_mode == 2 then delay = delay + (step_i - 1) * spd end
        if max_scatter > 0 then delay = delay + math.random(0, max_scatter) end

        local line_ofs  = math.floor(delay / 256)
        local rem_delay = delay % 256
        local note_li   = clamp(base_li + line_ofs, 1, total_lines)

        local col = phrase.lines[note_li].note_columns[ci]
        col.note_value   = clamp(chord.notes[ci] + ts, 0, 119)
        col.volume_value = note_velocity(ci, note_count)
        col.delay_value  = rem_delay

        -- Write note-off at end of length (only if < 100%)
        if chord_len_frac < 1.0 then
          local off_li = clamp(note_li + chord_lines, 1, total_lines)
          if off_li ~= note_li then
            local off_col = phrase.lines[off_li].note_columns[ci]
            if off_col.note_value == renoise.PatternLine.EMPTY_NOTE then
              off_col.note_value = renoise.PatternLine.NOTE_OFF
            end
          end
        end
      end
    end
  end

  local mode_info = ({ "chord", "strum", "arp" })[play_mode] or "?"
  renoise.app():show_status(string.format(
    "Neo Chords 2: wrote %d chords → phrase #%d  |  tr %+d  |  %s",
    #chords, idx, ts, mode_info))
end

-- ─── UI ──────────────────────────────────────────────────────────────────────

local function show_dialog()
  if state.dialog and state.dialog.visible then
    state.dialog:close()
  end
  math.randomseed(os.time())

  local vb   = renoise.ViewBuilder()
  local W    = 460
  local LW   = 110  -- label width

  -- Clamp indices to valid ranges
  state.group_idx = clamp(state.group_idx, 1, #groups)
  local cur_group = groups[state.group_idx]
  state.prog_in_group_idx = clamp(state.prog_in_group_idx, 1, #cur_group.progressions)

  -- ── Shared: staged progression preview ───────────────────────────────────
  local preview_text = vb:multiline_text {
    text   = state.preview
               and chords_to_string(state.preview)
               or  "(nothing staged yet — browse or randomize above)",
    width  = W - 20,
    height = 36,
  }
  local status_text = vb:text { text = "", width = W - 20 }

  -- ── Browse section ────────────────────────────────────────────────────────
  local prog_popup = vb:popup {
    items    = prog_items_for_group(cur_group),
    value    = state.prog_in_group_idx,
    width    = W - 20,
    notifier = function(v) state.prog_in_group_idx = v end,
  }

  local group_items = {}
  for _, g in ipairs(groups) do
    group_items[#group_items + 1] = string.format("Root: %s  (%d)", g.root, #g.progressions)
  end

  local browse_section = vb:column {
    spacing = 4,
    vb:text { text = "ROOT KEY", font = "bold" },
    vb:popup {
      items    = group_items,
      value    = state.group_idx,
      width    = W - 20,
      notifier = function(v)
        state.group_idx = v
        state.prog_in_group_idx = 1
        prog_popup.items = prog_items_for_group(groups[v])
        prog_popup.value = 1
      end,
    },
    vb:text { text = "PROGRESSION", font = "bold" },
    prog_popup,
    vb:button {
      text     = "Load Progression",
      width    = W - 20,
      notifier = function()
        local prog = groups[state.group_idx].progressions[state.prog_in_group_idx]
        local chords = {}
        for _, c in ipairs(prog.chords) do chords[#chords + 1] = copy_chord(c) end
        state.preview = chords
        preview_text.text = chords_to_string(state.preview)
        local lbs = {}
        for j = 1, math.min(4, #prog.chords) do lbs[#lbs + 1] = prog.chords[j].label end
        status_text.text = string.format("Loaded: %d.  %s", state.prog_in_group_idx, table.concat(lbs, "  "))
      end,
    },
  }

  -- ── Randomize section ─────────────────────────────────────────────────────
  local rand_section = vb:column {
    spacing = 4,
    vb:text { text = "METHOD", font = "bold" },
    vb:popup {
      items    = { "Recombine chords (weighted pool)", "Shuffle a full progression" },
      value    = state.rand_type,
      width    = W - 20,
      notifier = function(v) state.rand_type = v end,
    },
    vb:button {
      text     = "Randomize  →  Stage Result",
      width    = W - 20,
      notifier = function()
        state.preview = (state.rand_type == 1) and randomize_recombine() or randomize_shuffle()
        preview_text.text = chords_to_string(state.preview)
        status_text.text = "Staged. Adjust transpose / humanize, then Write to Phrase."
      end,
    },
  }

  -- ── Transpose ─────────────────────────────────────────────────────────────
  local function tr_desc(v)
    local oct = math.abs(v) / 12
    local sign = v >= 0 and "+" or ""
    if v == 0 then
      return "0 semitones"
    elseif math.abs(v) % 12 == 0 then
      local n = math.abs(v) / 12
      return string.format("%s%d semitones  (%d octave%s)", sign, v, n, n > 1 and "s" or "")
    else
      return string.format("%s%d semitones", sign, v)
    end
  end
  local tr_label = vb:text {
    text  = "Transpose by:",
    width = LW,
  }
  local tr_desc_label = vb:text {
    text  = tr_desc(state.transpose),
    width = 160,
  }
  local tr_vbox = vb:valuebox {
    min = -24, max = 24, value = state.transpose,
    notifier = function(v)
      state.transpose = v
      tr_desc_label.text = tr_desc(v)
    end,
  }
  local function tr_update(new_v)
    new_v = math.max(-24, math.min(24, new_v))
    state.transpose = new_v; tr_vbox.value = new_v
    tr_desc_label.text = tr_desc(new_v)
  end

  -- ── Humanize ──────────────────────────────────────────────────────────────
  local function hu_row(label_str, state_key)
    local lbl = vb:text { text = label_str, width = LW }
    local vbox = vb:valuebox {
      min = 0, max = 100, value = state[state_key],
      notifier = function(v)
        state[state_key] = v
      end,
    }
    local btn = vb:button {
      text = "0", width = 26,
      notifier = function() state[state_key] = 0; vbox.value = 0 end,
    }
    return vb:row { spacing = 4, lbl, vbox, vb:text { text = "%" }, btn }
  end
  local hu_timing_row = hu_row("Timing:", "humanize_timing")
  local hu_vel_row    = hu_row("Velocity:", "humanize_vel")
  local hu_feel_row   = hu_row("Feel:", "humanize_feel")
  -- ── Groove section ──────────────────────────────────────────────────────────────────
  local groove_feel_items = {}
  for _, grp in ipairs(groove_groups) do
    groove_feel_items[#groove_feel_items + 1] =
      string.format("%s (%d)", grp.feel, #grp.presets)
  end

  local function groove_items_for_feel(fi)
    local grp   = groove_groups[fi]
    local items = {}
    if grp then
      for i, pidx in ipairs(grp.presets) do
        items[#items + 1] = string.format("%d. %s", i, GROOVE_PRESETS[pidx].name)
      end
    end
    return items
  end

  local groove_preset_popup  -- forward declare

  local groove_feel_popup = vb:popup {
    items    = groove_feel_items,
    value    = state.groove_feel_idx,
    width    = W - 20,
    notifier = function(v)
      state.groove_feel_idx     = v
      state.groove_in_feel_idx  = 1
      local grp = groove_groups[v]
      if grp and #grp.presets > 0 then
        state.groove_pattern = GROOVE_PRESETS[grp.presets[1]].pattern
      end
      -- Update preset dropdown in-place (no dialog rebuild needed)
      groove_preset_popup.items = groove_items_for_feel(v)
      groove_preset_popup.value = 1
    end,
  }

  local gi_items = groove_items_for_feel(state.groove_feel_idx)
  groove_preset_popup = vb:popup {
    items    = gi_items,
    value    = clamp(state.groove_in_feel_idx, 1, math.max(1, #gi_items)),
    width    = W - 20,
    notifier = function(v)
      state.groove_in_feel_idx = v
      local grp = groove_groups[state.groove_feel_idx]
      if grp and grp.presets[v] then
        state.groove_pattern = GROOVE_PRESETS[grp.presets[v]].pattern
      end
    end,
  }

  local groove_rand_label = vb:text {
    text  = (state.groove_rand_desc ~= "") and state.groove_rand_desc or "Press Generate for a new rhythm",
    width = W - 20,
  }
  local groove_gen_btn = vb:button {
    text  = "Generate Random Groove",
    width = W - 20,
    notifier = function()
      local feel_names = { "Straight", "Moderate", "Syncopated" }
      local feel = feel_names[state.groove_feel_idx] or "Straight"
      local pat  = generate_groove(feel)
      state.groove_pattern  = pat
      state.groove_rand_desc = string.format(
        "Generated [%s]  %d chords  %.1f–%.1f beat slots",
        feel, #pat,
        pat[1].dur,
        pat[#pat].dur)
      groove_rand_label.text = state.groove_rand_desc
    end,
  }

  local groove_browse_section = vb:column {
    spacing = 4,
    groove_feel_popup,
    groove_preset_popup,
    vb:space { height = 4 },
    groove_gen_btn,
    groove_rand_label,
  }
  local groove_enable_switch = vb:switch {
    items    = { "Off", "On" },
    value    = state.groove_enabled and 2 or 1,
    width    = W - 20,
    notifier = function(v)
      state.groove_enabled = (v == 2)
      if not state.groove_enabled then
        state.groove_pattern = nil
      else
        local grp = groove_groups[state.groove_feel_idx]
        if grp and grp.presets[state.groove_in_feel_idx] then
          state.groove_pattern = GROOVE_PRESETS[grp.presets[state.groove_in_feel_idx]].pattern
        end
      end
      show_dialog()
    end,
  }
  -- ── Play mode + sub-controls ──────────────────────────────────────────────
  -- Chord sub-controls
  local cv_top_label = vb:text { text = "Root velocity:", width = LW }
  local cv_top_vbox  = vb:valuebox {
    min = 1, max = 127, value = state.chord_vel_top,
    notifier = function(v) state.chord_vel_top = v end,
  }
  local cv_bot_label = vb:text { text = "Top velocity:",  width = LW }
  local cv_bot_vbox  = vb:valuebox {
    min = 1, max = 127, value = state.chord_vel_bot,
    notifier = function(v) state.chord_vel_bot = v end,
  }
  local chord_len_popup = vb:popup {
    items    = CHORD_LEN_LABELS,
    value    = state.chord_length,
    width    = 80,
    notifier = function(v) state.chord_length = v end,
  }
  local chord_section = vb:column {
    spacing = 4,
    vb:row { spacing = 4, cv_top_label, cv_top_vbox, vb:text { text = "%" },
      vb:button { text = "80", width = 30, notifier = function() state.chord_vel_top = 80; cv_top_vbox.value = 80 end } },
    vb:row { spacing = 4, cv_bot_label, cv_bot_vbox, vb:text { text = "%" },
      vb:button { text = "60", width = 30, notifier = function() state.chord_vel_bot = 60; cv_bot_vbox.value = 60 end } },
    vb:row { spacing = 6, vb:text { text = "Note Length:", width = LW }, chord_len_popup },
  }

  -- Strum sub-controls
  local strum_speed_label = vb:text { text = "Note gap:", width = 70 }
  local strum_speed_vbox  = vb:valuebox {
    min = 1, max = 360, value = state.strum_speed,
    notifier = function(v) state.strum_speed = v end,
  }
  local function strum_upd(new_v)
    new_v = math.max(1, math.min(360, new_v))
    state.strum_speed = new_v; strum_speed_vbox.value = new_v
  end
  local strum_dir_switch = vb:switch {
    items    = { "↑ Up", "↓ Down" },
    value    = state.strum_dir,
    width    = W - 20,
    notifier = function(v) state.strum_dir = v end,
  }
  local strum_section = vb:column {
    spacing = 4,
    vb:row { spacing = 4, strum_speed_label, strum_speed_vbox, vb:text { text = "ticks" } },
    vb:space { height = 8 },
    strum_dir_switch,
  }

  -- Arp sub-controls
  local arp_step_popup = vb:popup {
    items    = ARP_STEP_LABELS,
    value    = state.arp_step,
    width    = 80,
    notifier = function(v) state.arp_step = v end,
  }
  local arp_dir_switch = vb:switch {
    items    = { "↑ Up", "↓ Down", "↑↓ Bounce", "↕ Shuffle", "⟳ PingPong", "⊛ Spiral" },
    value    = state.arp_dir,
    width    = W - 20,
    notifier = function(v) state.arp_dir = v end,
  }
  local arp_section = vb:column {
    spacing = 4,
    vb:row {
      spacing = 6,
      vb:text { text = "Subdivisions:", width = 80 },
      arp_step_popup,
    },
    vb:space { height = 8 },
    arp_dir_switch,
  }

  -- Play mode switch — rebuilds dialog to show only relevant controls
  local play_mode_switch = vb:switch {
    items    = { "Chord", "Strum", "Arp" },
    value    = state.play_mode,
    width    = W - 20,
    notifier = function(v)
      state.play_mode = v
      if v > 2 then
        state.groove_enabled = false
        state.groove_pattern  = nil
      end
      show_dialog()
    end,
  }

  -- ── Build section ─────────────────────────────────────────────────────────
  local build_pool      = filtered_chord_pool(state.build_filter_root)
  local build_items_now = build_pool_items(state.build_filter_root)
  state.build_chord_idx = clamp(state.build_chord_idx, 1, math.max(1, #build_pool))

  local build_queue_text = vb:multiline_text {
    text   = build_queue_to_string(),
    width  = W - 20,
    height = 36,
  }

  local build_chord_popup  -- forward declare

  local build_root_popup = vb:popup {
    items    = BUILD_ROOTS,
    value    = state.build_filter_root,
    width    = 80,
    notifier = function(v)
      state.build_filter_root = v
      state.build_chord_idx   = 1
      local new_items = build_pool_items(v)
      build_chord_popup.items = new_items
      build_chord_popup.value = 1
      stop_chord_preview()
    end,
  }

  build_chord_popup = vb:popup {
    items    = build_items_now,
    value    = state.build_chord_idx,
    width    = W - 20 - 80 - 4 - 80 - 4,
    notifier = function(v)
      state.build_chord_idx = v
      stop_chord_preview()
    end,
  }

  local build_dur_popup = vb:popup {
    items    = BUILD_DUR_LABELS,
    value    = state.build_chord_dur,
    width    = 100,
    notifier = function(v) state.build_chord_dur = v end,
  }

  local build_previewing = false  -- local toggle for preview button
  local build_preview_btn = vb:button {
    text  = "▶ Preview",
    width = 80,
    notifier = function()
      local pool = filtered_chord_pool(state.build_filter_root)
      local entry = pool[state.build_chord_idx]
      if not entry then return end
      if build_previewing then
        stop_chord_preview()
        build_previewing = false
      else
        play_chord_preview(entry.notes)
        build_previewing = true
      end
    end,
  }

  local build_section = vb:column {
    spacing = 4,
    vb:text { text = "CHORD", font = "bold" },
    vb:row { spacing = 4, build_root_popup, build_chord_popup, build_preview_btn },
    vb:space { height = 4 },
    vb:button {
      text  = "Add Chord",
      width = W - 20,
      notifier = function()
        local pool  = filtered_chord_pool(state.build_filter_root)
        local entry = pool[state.build_chord_idx]
        if not entry then return end
        state.build_queue[#state.build_queue + 1] = {
          notes    = entry.notes,
          label    = entry.label,
          duration = 2.0,
        }
        build_queue_text.text = build_queue_to_string()
      end,
    },
    vb:space { height = 4 },
    vb:text { text = "QUEUE", font = "bold" },
    build_queue_text,
    vb:row {
      spacing = 4,
      vb:button {
        text  = "Remove Last",
        width = (W - 20 - 4) / 2,
        notifier = function()
          if #state.build_queue > 0 then
            table.remove(state.build_queue)
            build_queue_text.text = build_queue_to_string()
          end
        end,
      },
      vb:button {
        text  = "Clear All",
        width = (W - 20 - 4) / 2,
        notifier = function()
          state.build_queue = {}
          build_queue_text.text = build_queue_to_string()
        end,
      },
    },
    vb:space { height = 4 },
    vb:button {
      text  = "Stage as Progression  →",
      width = W - 20,
      notifier = function()
        if #state.build_queue == 0 then return end
        local chords, beat = {}, 0
        for _, item in ipairs(state.build_queue) do
          chords[#chords + 1] = {
            notes    = item.notes,
            label    = item.label,
            onset    = beat,
            duration = item.duration,
          }
          beat = beat + item.duration
        end
        state.preview = chords
        state.mode    = 1   -- jump to Browse/staged view to show result
        show_dialog()
      end,
    },
  }

  -- ── Mode switch (rebuilds dialog to show/hide sections) ───────────────────
  local mode_switch = vb:switch {
    items    = { "Browse Originals", "Randomize", "Build" },
    value    = state.mode,
    width    = W - 20,
    notifier = function(v)
      state.mode = v
      show_dialog()
    end,
  }

  -- ── Full layout ───────────────────────────────────────────────────────────
  local function do_reset()
    stop_progression_preview()
    state.mode               = 1
    state.group_idx          = 1
    state.prog_in_group_idx  = 1
    state.rand_type          = 1
    state.transpose          = 0
    state.humanize_timing    = 0
    state.humanize_vel       = 0
    state.humanize_feel      = 0
    state.chord_vel_top      = 80
    state.chord_vel_bot      = 60
    state.chord_length       = 4
    state.play_mode          = 1
    state.strum_speed        = 40
    state.strum_dir          = 1
    state.arp_step           = 2
    state.arp_dir            = 1
    state.groove_enabled     = false
    state.groove_feel_idx    = 1
    state.groove_in_feel_idx = 1
    state.groove_pattern     = nil
    state.groove_rand_desc   = ""
    state.preview            = nil
    state.build_queue        = {}
    state.build_filter_root  = 1
    state.build_chord_idx    = 1
    state.build_chord_dur    = 2
    show_dialog()
  end

  local view = vb:column {
    margin  = 10,
    spacing = 8,

    vb:row {
      spacing = 0,
      vb:text { text = "NEO CHORDS 2", font = "bold", width = W - 20 - 100 },
      vb:button { text = "Reset All", width = 100, notifier = do_reset },
    },
    mode_switch,
    vb:space { height = 2 },

    -- Only the active section is included
    (state.mode == 1) and browse_section or
    (state.mode == 2) and rand_section   or
    build_section,

    vb:space { height = 4 },
    vb:text { text = "STAGED PROGRESSION", font = "bold" },
    vb:button {
      text  = state.preview_active and "Stop" or "▶ Preview",
      width = 80,
      notifier = function()
        if state.preview_active then
          stop_progression_preview()
          show_dialog()
        elseif state.preview then
          play_progression_preview(state.preview)
        end
      end,
    },
    preview_text,
    vb:text { text = "TRANSPOSE", font = "bold" },
    vb:row {
      spacing = 4,
      tr_label,
      tr_vbox,
      vb:button { text = "0", width = 26, notifier = function() tr_update(0) end },
      tr_desc_label,
    },
    vb:space { height = 10 },
    vb:text { text = "HUMANIZE", font = "bold" },
    hu_timing_row,
    hu_vel_row,
    hu_feel_row,

    vb:space { height = 10 },
    -- Play mode
    vb:text { text = "PLAY MODE", font = "bold" },
    play_mode_switch,
    (state.play_mode == 1) and chord_section or nil,
    (state.play_mode == 2) and strum_section  or nil,
    (state.play_mode == 3) and arp_section    or nil,

    -- Groove (Chord mode only)
    (state.play_mode <= 2) and vb:space { height = 6 }   or nil,
    (state.play_mode <= 2) and vb:text { text = "GROOVE", font = "bold" } or nil,
    (state.play_mode <= 2) and groove_enable_switch or nil,
    (state.play_mode <= 2 and state.groove_enabled) and groove_browse_section or nil,

    vb:space { height = 2 },
    vb:button {
      text     = "Write to Phrase",
      width    = W - 20,
      notifier = function()
        local chords_out = state.preview
        if state.groove_enabled and state.groove_pattern and chords_out then
          chords_out = apply_groove(chords_out, state.groove_pattern)
        end
        write_to_phrase(chords_out, state.transpose,
                        state.humanize_timing, state.humanize_vel, state.humanize_feel,
                        state.chord_vel_top, state.chord_vel_bot,
                        CHORD_LENGTHS[state.chord_length],
                        state.play_mode,
                        state.strum_speed, state.strum_dir,
                        ARP_STEPS[state.arp_step], state.arp_dir)
        status_text.text = string.format(
          "Written (tr %+d, t%d%% v%d%% f%d%%). Staged — change settings and write again.",
          state.transpose, state.humanize_timing, state.humanize_vel, state.humanize_feel)
      end,
    },
  }

  state.dialog = renoise.app():show_custom_dialog("Neo Chords 2", view)
end

-- ─── Tool Entry Points ────────────────────────────────────────────────────────

renoise.tool():add_menu_entry {
  name   = "Main Menu:Tools:Neo Chords 2...",
  invoke = show_dialog,
}

renoise.tool():add_menu_entry {
  name   = "Instrument Box:Neo Chords 2...",
  invoke = show_dialog,
}

renoise.tool():add_keybinding {
  name   = "Global:Tools:Neo Chords 2",
  invoke = show_dialog,
}
