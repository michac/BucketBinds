-- BucketBinds — Macros: the M5 macro engine (Phase A). Generate WoW macros
-- (create → place on a bar → bind a key) that the seed's raw-spell dump can't
-- express, reusing the addon's existing place/bind plumbing.
--
-- Phase B fills out the utility/prep band (keys 5–9): fall-through consumable
-- macros (BBhp/BBmana/BBdmg on the Alt item slots, BBflask on key 8), a generic
-- trinket macro (BBtrinket → key 6), a per-race racial (BBracial → key 7), and a
-- per-spec pre-pull buff (BBbuff → key 9). Item bodies /use every ID in a seed
-- group so whichever consumable the player carries fires. Mount stays a
-- placeholder (deferred to the OPie travel ring, M6).
--
-- Phase A ships two macros:
--   * BBfocus  — /focus, bound to key 5 (account scope; identical everywhere).
--   * BBintr   — a per-spec smart focus-interrupt that REPLACES the raw interrupt
--                spell the dump puts on bar 1 / slot 12 (key V). Every spec's V
--                becomes "interrupt your focus if it's a live enemy, else your
--                current target". Built from the seed's per-spec `Interrupt`
--                value, so Warlock (`Command Demon`) and Holy Priest
--                (`Holy Word: Chastise`) work with no special-casing; healer
--                specs with no `Interrupt` key skip gracefully.
--
-- Entry points (Apply / RunStandalone) are combat-protected — CreateMacro /
-- EditMacro / PlaceAction / PickupMacro / SetBinding are all lockdown-gated —
-- so they are only reached from Dump.Run (already combat-guarded) or
-- RunStandalone (adds its own guard). Never call Apply unguarded.
--
-- All API signatures verified against warcraft.wiki.gg for retail 12.0.x.

local ADDON, ns = ...

local Macros = {}
ns.Macros = Macros

local ACCOUNT_CAP = MAX_ACCOUNT_MACROS or 120
local CHARACTER_CAP = MAX_CHARACTER_MACROS or 18

local COLOR = "|cff40c0ff"
local WARN = "|cffffd100"
local ERR = "|cffff4040"
local R = "|r"
local function say(fmt, ...)
  ns.Emit(COLOR .. "BucketBinds" .. R .. ": " .. fmt:format(...))
end

-- The utility/prep band lives on the free "Left" bar (MultiBar4 = bar 5, base
-- slot 37). Key 5 → button 1 of that bar carries the set-focus macro; keys 5–9
-- are the intended utility/prep band (free bar 5, buttons 1–5).
local FOCUS_SLOT = 37                          -- MULTIACTIONBAR4BUTTON1 (free bar 5, button 1)
local FOCUS_CMD  = "MULTIACTIONBAR4BUTTON1"
local FOCUS_KEY  = "5"
local INTR_SLOT  = 12                           -- bar 1, slot 12 (the Interrupt bucket = key V)

-- Phase B item macros ride the bar-4 (Alt-layer) slots the seed reserves for the
-- item/trinket/racial buckets — abs slot = bar4 base(25) + (bucketSlot-1). The Alt
-- keys are ALSO bound by Dump.Run's bind loop (placeholder buckets included), so
-- for a plain /bb dump those binds are redundant; Apply sets them too so /bb macros
-- is self-sufficient standalone. The NEW keys 6/7 (trinket/racial, keyless in the
-- seed) and 8/9 (prep band) are owned solely by this macro pass.
local ITEM_SLOTS = { hp = 25, mana = 26, dmg = 27, trinket = 29, racial = 30 }
local ITEM_CMDS  = {
  hp = "MULTIACTIONBAR3BUTTON1", mana = "MULTIACTIONBAR3BUTTON2",
  dmg = "MULTIACTIONBAR3BUTTON3", trinket = "MULTIACTIONBAR3BUTTON5",
  racial = "MULTIACTIONBAR3BUTTON6",
}
local ITEM_KEYS  = {
  hp = "ALT-Q", mana = "ALT-E", dmg = "ALT-R", -- redundant w/ dump; set for standalone
  trinket = "6", racial = "7",                 -- NEW binds (prep band)
}
-- Prep macros ride the free "Left" bar (bar 5), like focus on button 1 / slot 37.
local PREP = {
  flask = { slot = 38, cmd = "MULTIACTIONBAR4BUTTON2", key = "8" },
  buff  = { slot = 39, cmd = "MULTIACTIONBAR4BUTTON3", key = "9" },
}

-- Seed categories the Phase-B macro pass fully handles, so Dump.Run drops them
-- from its `skipped (M5)` report. NOT handled (stay skipped): "Another Combat Item
-- If Needed" (no seed mapping), "Mount" (deferred to OPie M6), "Free", the Stance
-- buckets.
Macros.HANDLED_CATEGORIES = {
  ["Healthstone/Potion Macro"] = true, ["Drinking/Mana Potion Macro"] = true,
  ["Damage Potion"] = true, ["Trinket Macro"] = true, ["Racial Ability"] = true,
}

-- ---------------------------------------------------------------------------
-- Body builders (pure)
-- ---------------------------------------------------------------------------

-- Set-focus: static, universal. Icon is cosmetic — /focus has no tooltip spell.
function Macros.FocusBody()
  return {
    name = "BBfocus", perChar = false,
    icon = "Ability_Hunter_MastersCall",
    body = "/focus",
  }
end

-- Smart focus-interrupt: interrupt the focus if it's a live enemy, else the
-- current target. `interruptName` is the seed's per-spec `Interrupt` value;
-- returns nil for specs with no interrupt (6 healer specs → graceful skip). The
-- name string works for "Command Demon" (Warlock) and "Holy Word: Chastise"
-- (Holy Priest) with no special-casing. #showtooltip drives the real icon.
function Macros.InterruptBody(interruptName)
  if not interruptName or interruptName == "" then return nil end
  return {
    name = "BBintr", perChar = true,
    icon = "INV_MISC_QUESTIONMARK",
    body = "#showtooltip " .. interruptName
         .. "\n/cast [@focus,harm,nodead][] " .. interruptName,
  }
end

-- Auto-icon: "?" tells WoW to track the macro's active #showtooltip item/spell,
-- so a fall-through consumable macro always shows whatever it would actually use.
local ICON = "INV_MISC_QUESTIONMARK"
local MACRO_CAP = 255 -- WoW silently truncates a macro body past this.

-- Fall-through consumable macro (Phase B): #showtooltip + optional prefix lines +
-- a /use item:<id> for EVERY id in the seed group (q2 higher-rank first, then q1),
-- so whichever potion/flask the player carries fires. Guards the 255-char cap by
-- dropping trailing /use lines (and warning) — a group is ~8 lines (~180 chars),
-- safe, but the Health group (+ Healthstone prefix) is the longest, so verify it.
-- Returns a { name, perChar, icon, body } descriptor (like FocusBody).
function Macros.ConsumableBody(name, perChar, icon, group, prefixLines)
  local cand = {}
  for _, l in ipairs(prefixLines or {}) do cand[#cand + 1] = l end
  local rows = ns.SEED and ns.SEED.items and ns.SEED.items[group]
  if rows then
    for _, pair in ipairs(rows) do
      for _, id in ipairs(pair) do cand[#cand + 1] = "/use item:" .. id end
    end
  end
  local out = { "#showtooltip" }
  local len, truncated = #out[1], false
  for _, line in ipairs(cand) do
    local newLen = len + 1 + #line -- +1 for the "\n" join
    if newLen > MACRO_CAP then truncated = true break end
    out[#out + 1] = line
    len = newLen
  end
  if truncated then
    say(WARN .. "%s exceeded %d chars — trailing items dropped." .. R, name, MACRO_CAP)
  end
  return { name = name, perChar = perChar, icon = icon or ICON,
           body = table.concat(out, "\n") }
end

-- Generic on-use trinket macro: fire both trinket slots (13 = upper, 14 = lower).
function Macros.TrinketBody()
  return "#showtooltip 13\n/use 13\n/use 14"
end

-- Race → on-use combat/utility racial. Hardcoded static game data (racials aren't
-- in the Bellular seed). @verify-ingame: WoW renames/adds racials across
-- expansions — re-confirm the whole table on a new patch, esp. any Midnight-new
-- or renamed race (Earthen/Dracthyr and the allied races).
local RACIALS = {
  Orc = "Blood Fury", Troll = "Berserking", BloodElf = "Arcane Torrent",
  Scourge = "Will of the Forsaken", Tauren = "War Stomp", Dwarf = "Stoneform",
  NightElf = "Shadowmeld", Draenei = "Gift of the Naaru", Gnome = "Escape Artist",
  Human = "Every Man for Himself", Worgen = "Darkflight", Goblin = "Rocket Barrage",
  Pandaren = "Quaking Palm", VoidElf = "Spatial Rift",
  LightforgedDraenei = "Light's Judgment", HighmountainTauren = "Bull Rush",
  Nightborne = "Arcane Pulse", MagharOrc = "Ancestral Call",
  DarkIronDwarf = "Fireblood", KulTiran = "Haymaker",
  ZandalariTroll = "Regeneratin'", Mechagnome = "Hyper Organic Light Originator",
  Vulpera = "Bag of Tricks", Dracthyr = "Wing Buffet", Earthen = "Azerite Surge",
}

-- Race-file token (select(2, UnitRace)) → "#showtooltip <r>\n/cast <r>"; nil if
-- the race isn't mapped (→ BBracial not created, reported skipped).
function Macros.RacialBody(raceFile)
  local r = raceFile and RACIALS[raceFile]
  if not r then return nil end
  return "#showtooltip " .. r .. "\n/cast " .. r
end

-- Per-spec pre-pull buff macro from ns.SEED.specBuffs (pre-resolved by
-- gen_data_lua.py). #showtooltip + one /cast per buff; nil if the spec has no
-- buff row (DK/DH/Hunter/Warlock, healers with no self-buff, etc → skipped).
function Macros.BuffBody(seedKey)
  local buffs = ns.SEED and ns.SEED.specBuffs and ns.SEED.specBuffs[seedKey]
  if not buffs or #buffs == 0 then return nil end
  local lines = { "#showtooltip" }
  for _, b in ipairs(buffs) do lines[#lines + 1] = "/cast " .. b end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Macro CRUD (cap-aware upsert that returns the index — the M1 applyMacros
-- variant only returns counts; Phase A needs the index to place the macro)
-- ---------------------------------------------------------------------------

-- Update a same-named macro, else create it if there's room. Returns the macro
-- index (nil when capped) and a status ∈ {"edited","created","capped"}.
-- CreateMacro returns the new index — captured for placeMacro.
local function upsert(name, icon, body, perChar)
  local idx = name and GetMacroIndexByName(name) or 0
  if idx and idx > 0 then
    EditMacro(idx, name, icon, body)
    return idx, "edited"
  end
  local numAccount, numChar = GetNumMacros()
  local room = perChar and (numChar < CHARACTER_CAP) or (numAccount < ACCOUNT_CAP)
  if not room then return nil, "capped" end
  local newIdx = CreateMacro(name, icon, body, perChar)
  return newIdx, "created"
end

-- Guarded pickup→place idiom (mirrors Snapshot.applyActions' macro branch /
-- Dump.placeSpell). Only places if the pickup actually loaded the cursor.
local function placeMacro(idx, absSlot)
  if not idx or absSlot < 1 or absSlot > 180 then return false end
  ClearCursor()
  PickupMacro(idx)
  if GetCursorInfo() then
    PlaceAction(absSlot)
    ClearCursor()
    return true
  end
  ClearCursor()
  return false
end

-- Copy of Dump.clearSlot (4-line body) — kept local so Macros doesn't depend on
-- a Dump internal.
local function clearSlot(absSlot)
  if absSlot >= 1 and absSlot <= 180 and GetActionInfo(absSlot) then
    PickupAction(absSlot)
    ClearCursor()
  end
end

-- Vacate whatever key(s) currently drive `cmd`, then bind `key` to it — the
-- Phase-A "one key per managed slot" idiom, so re-runs stay 1:1 and relocating a
-- bucket doesn't leave a stale duplicate binding.
local function bindKey(key, cmd)
  local k1, k2 = GetBindingKey(cmd)
  if k1 then SetBinding(k1) end
  if k2 then SetBinding(k2) end
  SetBinding(key, cmd)
end

-- ---------------------------------------------------------------------------
-- Apply: the shared engine (called from Dump.Run post-pass and RunStandalone)
-- ---------------------------------------------------------------------------

-- opts = { fromDump, formOffsets, bar1IDs, noBind }.
-- ALL placement/binding here is protected → the CALLER guarantees out-of-combat.
-- Returns a report table { created, edited, capped, focusPlaced, intrPlaced,
-- intrSkipped, itemsPlaced, itemsCapped, racialSkipped, buffSkipped, flaskPlaced,
-- buffPlaced }.
function Macros.Apply(seedKey, opts)
  opts = opts or {}
  local spec = ns.SEED and ns.SEED.specs[seedKey]
  local rep = { created = 0, edited = 0, capped = 0,
                focusPlaced = false, intrPlaced = false, intrSkipped = false,
                itemsPlaced = 0, itemsCapped = 0, racialSkipped = false,
                buffSkipped = false, flaskPlaced = false, buffPlaced = false }

  local function tally(st)
    if st == "created" then rep.created = rep.created + 1
    elseif st == "edited" then rep.edited = rep.edited + 1
    elseif st == "capped" then rep.capped = rep.capped + 1 end
  end

  -- 1) Set-focus macro → free bar 5 button 1, bound to key 5.
  local fb = Macros.FocusBody()
  local fidx, fst = upsert(fb.name, fb.icon, fb.body, fb.perChar)
  tally(fst)
  if fidx then
    if placeMacro(fidx, FOCUS_SLOT) then rep.focusPlaced = true end
    if not opts.noBind then
      -- Vacate any key already bound to this slot before claiming key 5, so the
      -- 1:1 "one key per managed slot" invariant holds.
      local k1, k2 = GetBindingKey(FOCUS_CMD)
      if k1 then SetBinding(k1) end
      if k2 then SetBinding(k2) end
      SetBinding(FOCUS_KEY, FOCUS_CMD)
    end
  end

  -- 2) Smart interrupt macro → REPLACES the raw interrupt spell the dump placed
  --    on bar 1 / slot 12 (and its form-bar mirrors).
  local ib = Macros.InterruptBody(spec and spec["Interrupt"])
  if ib then
    local iidx, ist = upsert(ib.name, ib.icon, ib.body, ib.perChar)
    tally(ist)
    if iidx then
      if placeMacro(iidx, INTR_SLOT) then rep.intrPlaced = true end
      -- Mirror onto every form/stance bonus bar (same formula as Dump.Run), so
      -- a form class' V fires the macro, not the raw spell, on the form bar.
      for _, off in ipairs(opts.formOffsets or {}) do
        placeMacro(iidx, 1 + (5 + off) * 12 + (INTR_SLOT - 1))
      end
      -- ⚠ Hazard 1: Dump.Run stashes bar1IDs into BucketBindsDB.lastDump.bar1
      -- AFTER this post-pass, and onShapeshift re-places lastDump.bar1[slot] on
      -- every form entry. Nil out index 12 so a form class shifting form doesn't
      -- re-place the RAW interrupt spell over the macro on slot 12.
      if opts.bar1IDs then opts.bar1IDs[INTR_SLOT] = nil end
    end
  else
    rep.intrSkipped = true -- no interrupt for this spec (healer) — slot V left as placed
  end

  -- 3) Item + prep pass (Phase B) — all under the same out-of-combat guarantee.
  -- Place a macro on `slot`, and (unless noBind) claim `key` for `cmd`. Returns
  -- true if the macro landed on the slot.
  local function applyMacro(name, icon, body, perChar, slot, cmd, key)
    local idx, st = upsert(name, icon, body, perChar)
    tally(st)
    local placed = false
    if idx then
      placed = placeMacro(idx, slot)
      if key and not opts.noBind then bindKey(key, cmd) end
    end
    return placed, st
  end

  -- Item macros → bar-4 Alt-layer slots (Alt keys pre-bound by the dump; set here
  -- too for standalone). Account scope — identical on every character.
  local function item(desc, slotKey)
    local placed, st = applyMacro(desc.name, desc.icon, desc.body, desc.perChar,
      ITEM_SLOTS[slotKey], ITEM_CMDS[slotKey], ITEM_KEYS[slotKey])
    if placed then rep.itemsPlaced = rep.itemsPlaced + 1 end
    if st == "capped" then rep.itemsCapped = rep.itemsCapped + 1 end
  end
  item(Macros.ConsumableBody("BBhp", false, ICON, "Health", { "/use Healthstone" }), "hp")
  item(Macros.ConsumableBody("BBmana", false, ICON, "Mana"), "mana")
  item(Macros.ConsumableBody("BBdmg", false, ICON, "Damage"), "dmg")
  item({ name = "BBtrinket", perChar = false, icon = ICON, body = Macros.TrinketBody() }, "trinket")

  -- Racial → per-char (race differs per character); skip on an unmapped race.
  local racialBody = Macros.RacialBody(select(2, UnitRace("player")))
  if racialBody then
    item({ name = "BBracial", perChar = true, icon = ICON, body = racialBody }, "racial")
  else
    rep.racialSkipped = true
  end

  -- Prep band → free bar-5 buttons (keys 8/9). Flask = account; buff = per-char.
  local fplaced = applyMacro("BBflask", ICON,
    Macros.ConsumableBody("BBflask", false, ICON, "Flasks").body, false,
    PREP.flask.slot, PREP.flask.cmd, PREP.flask.key)
  rep.flaskPlaced = fplaced

  local buffBody = Macros.BuffBody(seedKey)
  if buffBody then
    rep.buffPlaced = applyMacro("BBbuff", ICON, buffBody, true,
      PREP.buff.slot, PREP.buff.cmd, PREP.buff.key)
  else
    rep.buffSkipped = true
  end

  return rep
end

-- ---------------------------------------------------------------------------
-- Standalone: /bb macros [Spec]
-- ---------------------------------------------------------------------------

-- opts = { spec, noBind }. Combat-guarded, self-backing-up — the same shape as
-- Dump.Run, but only the macro post-pass. Resolves the seed key the same way
-- cmdDump does (Dump.Resolve).
function Macros.RunStandalone(opts)
  opts = opts or {}
  if not ns.Dump then
    ns.Emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load (needed for spec resolution).")
    return
  end

  if InCombatLockdown() then
    if ns.QueueAction then ns.QueueAction(function() Macros.RunStandalone(opts) end) end
    say("in combat — macros deferred until you leave combat.")
    return "deferred"
  end

  local seedKey = ns.Dump.Resolve(opts.spec or "")
  if not seedKey then
    local _, ct = UnitClass("player")
    if (opts.spec or "") == "" then
      ns.Emit(ERR .. "BucketBinds" .. R .. ": couldn't detect your spec. Pick one:")
      for _, k in ipairs(ns.Dump.AvailableKeys(ct)) do ns.Emit("  " .. WARN .. k .. R) end
    else
      ns.Emit(ERR .. "BucketBinds" .. R .. ": no spec matching '" .. tostring(opts.spec) .. "'. Available:")
      for _, k in ipairs(ns.Dump.AvailableKeys()) do ns.Emit("  " .. WARN .. k .. R) end
    end
    return
  end

  -- Auto-backup so /bb undo reverts standalone macro placement too (M1 reuse).
  BucketBindsDB.autobackup = ns.Snapshot.Capture()
  if SetActionBarToggles then SetActionBarToggles(1, 1, 1, 1, 1) end

  local formOffsets = ns.Dump.FormOffsets()
  local rep = Macros.Apply(seedKey, {
    fromDump = false, formOffsets = formOffsets, bar1IDs = {}, noBind = opts.noBind,
  })

  if not opts.noBind then SaveBindings(GetCurrentBindingSet()) end

  say("macros %s — %d created, %d updated%s.", seedKey, rep.created, rep.edited,
    rep.capped > 0 and (WARN .. " (out of macro slots!)" .. R) or "")
  say("  set-focus → key %s%s; smart interrupt → V%s.",
    FOCUS_KEY, rep.focusPlaced and "" or (WARN .. " (not placed)" .. R),
    rep.intrSkipped and (WARN .. " skipped — no interrupt for this spec" .. R)
      or (rep.intrPlaced and "" or (WARN .. " (not placed)" .. R)))
  say("  items: %d placed%s (Alt+Q/E/R, trinket→6, racial→%s); prep: flask→8%s, buff→9%s.",
    rep.itemsPlaced, rep.itemsCapped > 0 and (WARN .. " (capped!)" .. R) or "",
    rep.racialSkipped and (WARN .. "skipped" .. R) or "7",
    rep.flaskPlaced and "" or (WARN .. " (not placed)" .. R),
    rep.buffSkipped and (WARN .. " skipped — no buff for this spec" .. R)
      or (rep.buffPlaced and "" or (WARN .. " (not placed)" .. R)))
  say("clear them with " .. "/bb macros clear" .. "; " .. "/bb undo" .. " reverts everything.")
  return "applied"
end

-- ---------------------------------------------------------------------------
-- Clear: /bb macros clear
-- ---------------------------------------------------------------------------

-- Delete the two generated macros, clear the focus slot, unbind key 5. Slot 12
-- (interrupt) is left empty — a later /bb dump refills it with the raw spell;
-- /bb undo fully reverts to the pre-macro/pre-dump state.
function Macros.Clear(opts)
  opts = opts or {}
  if InCombatLockdown() then
    if ns.QueueAction then ns.QueueAction(function() Macros.Clear(opts) end) end
    say("in combat — macro clear deferred until you leave combat.")
    return "deferred"
  end

  local deleted = 0
  for _, name in ipairs({ "BBfocus", "BBintr", "BBhp", "BBmana", "BBdmg",
                          "BBtrinket", "BBracial", "BBflask", "BBbuff" }) do
    local idx = GetMacroIndexByName(name)
    if idx and idx > 0 then
      DeleteMacro(idx)
      deleted = deleted + 1
    end
  end

  -- Clear the focus + item + prep slots this macro pass owns.
  clearSlot(FOCUS_SLOT)
  for _, s in pairs(ITEM_SLOTS) do clearSlot(s) end
  clearSlot(PREP.flask.slot)
  clearSlot(PREP.buff.slot)

  -- Unbind key 5 (focus) and the NEW keys 6/7/8/9 the macro pass owns. The Alt
  -- item keys (Alt+Q/E/R/F) belong to the dump layout, so leave them.
  SetBinding(FOCUS_KEY)
  SetBinding(ITEM_KEYS.trinket)
  SetBinding(ITEM_KEYS.racial)
  SetBinding(PREP.flask.key)
  SetBinding(PREP.buff.key)
  SaveBindings(GetCurrentBindingSet())

  say("cleared %d generated macro(s); keys %s/6/7/8/9 unbound, item+prep slots cleared.",
    deleted, FOCUS_KEY)
  say("note: interrupt slot V is left empty — " .. "/bb dump" .. " refills it.")
  return "cleared"
end
