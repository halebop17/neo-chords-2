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
  humanize          = 0,  -- 0-100 (%)
  play_mode         = 1,  -- 1=Chord, 2=Strum, 3=Arp
  strum_speed       = 10, -- ticks between notes (1=very fast, 60=slow sweep)
  strum_dir         = 1,  -- 1=up (low→high), 2=down (high→low)
  arp_step          = 2,  -- index into ARP_STEPS
  arp_dir           = 1,  -- 1=Up, 2=Down, 3=Up-Down
  preview           = nil,
  dialog            = nil,
}

local ARP_STEPS       = { 1, 2, 4, 8 }          -- lines per arp note
local ARP_STEP_LABELS = { "1/16", "1/8", "1/4", "1/2" }

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
  local parts = {}
  for _, c in ipairs(chords) do parts[#parts + 1] = c.label end
  return table.concat(parts, "  →  ")
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

-- ─── Phrase Writer ───────────────────────────────────────────────────────────

local LPB = 8

local function write_to_phrase(chords, transpose_st, humanize_pct, play_mode,
                               strum_speed, strum_dir, arp_step_lines, arp_dir)
  if not chords or #chords == 0 then
    renoise.app():show_warning("No progression staged. Browse or Randomize first.")
    return
  end
  local instrument = renoise.song().selected_instrument
  if not instrument then
    renoise.app():show_warning("No instrument selected.")
    return
  end

  local last = chords[#chords]
  local total_lines = clamp(math.ceil((last.onset + last.duration) * LPB), 16, 512)
  local max_notes = 0
  for _, c in ipairs(chords) do max_notes = math.max(max_notes, #c.notes) end
  max_notes = clamp(max_notes, 2, 12)

  local idx = #instrument.phrases + 1
  instrument:insert_phrase_at(idx)
  local phrase = instrument.phrases[idx]
  phrase.name = string.format("Neo Chords %d", idx)
  phrase.number_of_lines = total_lines
  phrase.lpb = LPB
  phrase.looping = true
  phrase.visible_note_columns = max_notes

  local ts      = clamp(transpose_st, -48, 48)
  local max_hum = math.floor(humanize_pct / 100 * 15)
  local spd     = clamp(strum_speed, 1, 120)

  -- Enable delay column for chord/strum modes when needed
  phrase.delay_column_visible = (play_mode ~= 3) and (play_mode == 2 or max_hum > 0)

  if play_mode == 3 then
    -- ── ARP mode: spread notes across lines ────────────────────────────────
    phrase.visible_note_columns = 1
    local step = clamp(arp_step_lines, 1, 8)

    for _, chord in ipairs(chords) do
      local note_count   = math.min(#chord.notes, max_notes)
      local chord_lines  = math.floor(chord.duration * LPB)  -- lines this chord occupies
      local base_li      = clamp(math.floor(chord.onset * LPB) + 1, 1, total_lines)

      -- Build the arp sequence from sorted notes
      local sorted = {}
      for i = 1, note_count do sorted[i] = chord.notes[i] end
      -- sorted is already low→high from parser

      -- Build directional sequence
      local seq = {}
      if arp_dir == 1 then          -- Up
        for i = 1, note_count do seq[#seq + 1] = sorted[i] end
      elseif arp_dir == 2 then      -- Down
        for i = note_count, 1, -1 do seq[#seq + 1] = sorted[i] end
      else                          -- Up-Down (bounce, no repeated top/bottom)
        for i = 1, note_count do seq[#seq + 1] = sorted[i] end
        for i = note_count - 1, 2, -1 do seq[#seq + 1] = sorted[i] end
      end

      if #seq == 0 then seq = { chord.notes[1] } end

      -- Fill lines within the chord's duration with cycling arp notes
      local seq_i = 1
      local li    = base_li
      while li <= math.min(base_li + chord_lines - 1, total_lines) do
        local col = phrase.lines[li].note_columns[1]
        col.note_value = clamp(seq[seq_i] + ts, 0, 119)
        seq_i = (seq_i % #seq) + 1
        li = li + step
      end
    end

  else
    -- ── Chord / Strum mode ─────────────────────────────────────────────────
    for _, chord in ipairs(chords) do
      local li   = clamp(math.floor(chord.onset * LPB) + 1, 1, total_lines)
      local line = phrase.lines[li]
      local note_count = math.min(#chord.notes, max_notes)

      local order = {}
      if play_mode == 2 and strum_dir == 2 then
        for i = note_count, 1, -1 do order[#order + 1] = i end
      else
        for i = 1, note_count do order[#order + 1] = i end
      end

      for step_i, ci in ipairs(order) do
        local col = line.note_columns[ci]
        col.note_value = clamp(chord.notes[ci] + ts, 0, 119)
        local delay = 0
        if play_mode == 2 then delay = delay + (step_i - 1) * spd end
        if max_hum > 0   then delay = delay + math.random(0, max_hum) end
        col.delay_value = clamp(delay, 0, 255)
      end
    end
  end

  local mode_info = ({ "chord", "strum", "arp" })[play_mode] or "?"
  renoise.app():show_status(string.format(
    "Neo Chords 2: wrote %d chords → phrase #%d  |  tr %+d  |  hu %d%%  |  %s",
    #chords, idx, ts, humanize_pct, mode_info))
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
    height = 52,
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
        status_text.text = "Loaded: " .. prog.name
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
  local tr_label = vb:text {
    text  = string.format("Transpose: %+d st", state.transpose),
    width = LW,
  }
  local tr_slider = vb:slider {
    min = -24, max = 24, value = state.transpose,
    width    = W - LW - 36,
    notifier = function(v)
      state.transpose = math.floor(v + 0.5)
      tr_label.text = string.format("Transpose: %+d st", state.transpose)
    end,
  }

  -- ── Humanize ──────────────────────────────────────────────────────────────
  local hu_label = vb:text {
    text  = string.format("Humanize:  %d%%", state.humanize),
    width = LW,
  }
  local hu_slider = vb:slider {
    min = 0, max = 100, value = state.humanize,
    width    = W - LW - 36,
    notifier = function(v)
      state.humanize = math.floor(v + 0.5)
      hu_label.text = string.format("Humanize:  %d%%", state.humanize)
    end,
  }

  -- ── Play mode + sub-controls ──────────────────────────────────────────────
  -- Strum sub-controls
  local strum_speed_label = vb:text {
    text  = string.format("Speed: %d tk", state.strum_speed),
    width = 72,
  }
  local strum_speed_slider = vb:slider {
    min = 1, max = 60, value = state.strum_speed,
    width    = W - 72 - 36,
    active   = (state.play_mode == 2),
    notifier = function(v)
      state.strum_speed = math.floor(v + 0.5)
      strum_speed_label.text = string.format("Speed: %d tk", state.strum_speed)
    end,
  }
  local strum_dir_switch = vb:switch {
    items    = { "↑ Up", "↓ Down" },
    value    = state.strum_dir,
    width    = W - 20,
    active   = (state.play_mode == 2),
    notifier = function(v) state.strum_dir = v end,
  }
  local strum_section = vb:column {
    spacing = 4,
    vb:row { spacing = 4, strum_speed_label, strum_speed_slider },
    strum_dir_switch,
  }

  -- Arp sub-controls
  local arp_step_popup = vb:popup {
    items    = ARP_STEP_LABELS,
    value    = state.arp_step,
    width    = 80,
    active   = (state.play_mode == 3),
    notifier = function(v) state.arp_step = v end,
  }
  local arp_dir_switch = vb:switch {
    items    = { "↑ Up", "↓ Down", "↑↓ Bounce" },
    value    = state.arp_dir,
    width    = W - 20,
    active   = (state.play_mode == 3),
    notifier = function(v) state.arp_dir = v end,
  }
  local arp_section = vb:column {
    spacing = 4,
    vb:row {
      spacing = 6,
      vb:text { text = "Step:", width = 36 },
      arp_step_popup,
    },
    arp_dir_switch,
  }

  -- Play mode switch — shows/hides sub-sections via active flag
  local play_mode_switch = vb:switch {
    items    = { "Chord", "Strum", "Arp" },
    value    = state.play_mode,
    width    = W - 20,
    notifier = function(v)
      state.play_mode = v
      local is_strum = (v == 2)
      local is_arp   = (v == 3)
      strum_speed_slider.active = is_strum
      strum_dir_switch.active   = is_strum
      arp_step_popup.active     = is_arp
      arp_dir_switch.active     = is_arp
    end,
  }

  -- ── Mode switch (rebuilds dialog to show/hide sections) ───────────────────
  local mode_switch = vb:switch {
    items    = { "Browse Originals", "Randomize" },
    value    = state.mode,
    width    = W - 20,
    notifier = function(v)
      state.mode = v
      show_dialog()
    end,
  }

  -- ── Full layout ───────────────────────────────────────────────────────────
  local view = vb:column {
    margin  = 10,
    spacing = 8,

    vb:text { text = "NEO CHORDS 2", font = "bold", width = W - 20 },
    mode_switch,
    vb:space { height = 2 },

    -- Only the active section is included
    (state.mode == 1) and browse_section or rand_section,

    vb:space { height = 4 },
    vb:text { text = "STAGED PROGRESSION", font = "bold" },
    preview_text,

    vb:row {
      spacing = 4,
      tr_label, tr_slider,
      vb:button {
        text = "0", width = 26,
        notifier = function()
          state.transpose = 0; tr_slider.value = 0
          tr_label.text = "Transpose:  0 st"
        end,
      },
    },
    vb:row {
      spacing = 4,
      hu_label, hu_slider,
      vb:button {
        text = "0", width = 26,
        notifier = function()
          state.humanize = 0; hu_slider.value = 0
          hu_label.text = "Humanize:   0%"
        end,
      },
    },

    -- Play mode
    vb:text { text = "PLAY MODE", font = "bold" },
    play_mode_switch,
    strum_section,
    arp_section,

    vb:space { height = 2 },
    vb:button {
      text     = "Write to Phrase",
      width    = W - 20,
      notifier = function()
        write_to_phrase(state.preview, state.transpose, state.humanize,
                        state.play_mode,
                        state.strum_speed, state.strum_dir,
                        ARP_STEPS[state.arp_step], state.arp_dir)
        status_text.text = string.format(
          "Written (tr %+d, hu %d%%). Progression still staged — change transpose and write again.",
          state.transpose, state.humanize)
      end,
    },
    status_text,
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
