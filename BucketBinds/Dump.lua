-- BucketBinds — Dump: the M2 payoff. Given the player's class+spec, walk the
-- seed's 48 placeable buckets, resolve each bucket's ability name to a runtime
-- spell ID, place it on the fixed action slot the bucket owns, mirror the main
-- bar onto each form/stance bonus bar, and set the key→slot binding — a one-shot
-- "here's a complete, ergonomic keybind layout" dump.
--
-- Bar model (decided 2026-07-10; re-layout 2026-07-14): direct modifier binds
-- on all-visible stock bars, no paging, one modifier layer per physical bar —
-- bar 1 = 12 unmodified keys, bar 2 = Shift, bar 3 = Ctrl, bar 4 = Alt (bar 5
-- is free). Each (bar, slot) maps 1:1 to one absolute action slot + one
-- SetBinding command; the seed carries the explicit key per combo.
--
-- Combat-gated like Snapshot.Apply (defers via ns.QueueAction). Takes an
-- auto-backup into BucketBindsDB.autobackup first, so /bb undo reverts a dump.
--
-- The Alt-bar item/trinket/racial macro slots + the 4 Stance buckets carry
-- placeholder names (no single spell); they're reported as "skipped (M5)",
-- never silently dropped.
--
-- All API signatures verified against warcraft.wiki.gg for retail 12.0.x.

local ADDON, ns = ...

local Dump = {}
ns.Dump = Dump

local COLOR = "|cff40c0ff"
local WARN = "|cffffd100"
local ERR = "|cffff4040"
local R = "|r"
local function say(fmt, ...)
  ns.Emit(COLOR .. "BucketBinds" .. R .. ": " .. fmt:format(...))
end

-- ---------------------------------------------------------------------------
-- Static maps (the cosmetic/layout layer — easy to retune)
-- ---------------------------------------------------------------------------

-- classToken (UnitClass 2nd return) → English display name. The seed keys use
-- display names ("Death Knight/Blood"); driving the class half off the token
-- keeps spec detection locale-independent for the class part.
local CLASS_DISPLAY = {
  DEATHKNIGHT = "Death Knight", DEMONHUNTER = "Demon Hunter", DRUID = "Druid",
  EVOKER = "Evoker", HUNTER = "Hunter", MAGE = "Mage", MONK = "Monk",
  PALADIN = "Paladin", PRIEST = "Priest", ROGUE = "Rogue", SHAMAN = "Shaman",
  WARLOCK = "Warlock", WARRIOR = "Warrior",
}

-- seed bar → { absolute-slot base, SetBinding command prefix }.
-- absSlot = base + (slot-1); command = prefix .. slot. Only bar 1 (Main) pages
-- with form; MultiBars 2–5 are static and correct in every form automatically.
local BAR_MAP = {
  [1] = { base = 1,  prefix = "ACTIONBUTTON" },          -- Main
  [2] = { base = 61, prefix = "MULTIACTIONBAR1BUTTON" }, -- BottomLeft
  [3] = { base = 49, prefix = "MULTIACTIONBAR2BUTTON" }, -- BottomRight
  [4] = { base = 25, prefix = "MULTIACTIONBAR3BUTTON" }, -- Right
  [5] = { base = 37, prefix = "MULTIACTIONBAR4BUTTON" }, -- Left
}

-- Bonus-bar offsets each form-class uses, so bar-1's 8 abilities get mirrored
-- onto the form bars (bindings stay ACTIONBUTTON1–8; they auto-page). Static
-- best-effort — the UPDATE_SHAPESHIFT_FORM hook below self-heals any form this
-- table gets wrong. Bonus-bar base slot = 1 + (5+offset)*12 (offset 1→73,
-- 2→85, 3→97, 4→109).
local FORM_BONUS_BARS = {
  DRUID   = { 1, 3, 4 }, -- Cat, Bear, Moonkin (Tree = 2 if talented)
  ROGUE   = { 1 },       -- Stealth
  WARRIOR = { 1, 2, 3 }, -- stances (if they page in 12.0.x)
  PRIEST  = { 1 },       -- Shadowform (if it pages in 12.0.x)
}

-- The form/stance bonus-bar offsets for a class, so the M5 macro post-pass can
-- mirror the interrupt macro onto the same form bars the dump mirrors bar 1 to.
function Dump.FormOffsets(classToken)
  classToken = classToken or select(2, UnitClass("player"))
  return FORM_BONUS_BARS[classToken]
end

-- Classes whose contextual ALT+1..8 row is the PET bar (BONUSACTIONBUTTON). Every
-- other class either uses the STANCE bar (detected at runtime via
-- GetNumShapeshiftForms) or has neither. Binding pet keys for a class/spec that
-- isn't currently pet'd is harmless — the bar just stays empty until a pet is out.
-- MAGE is deliberately omitted: only Frost *might* have a controllable pet bar in
-- 12.0.7 (uncertain), so we don't bind an empty pet row for all three specs on a
-- guess. Add MAGE = true here if Frost's elemental turns out to want it.
local PET_CLASS = {
  HUNTER = true, WARLOCK = true, DEATHKNIGHT = true,
}

-- Placeholder ability values the seed uses for non-spell buckets. These never
-- resolve to a spell and never count as "unresolved" — they route to the M5
-- skip list (macro/summon generation is a separate milestone).
local PLACEHOLDER = {
  ["Mount"] = true, ["Free"] = true, ["Racial Ability"] = true,
  ["Healthstone/Potion Macro"] = true, ["Drinking/Mana Potion Macro"] = true,
  ["Damage Potion"] = true, ["Another Combat Item If Needed"] = true,
  ["Trinket Macro"] = true,
}

-- keybind notation → SetBinding key string. One optional modifier
-- (S/C/A → SHIFT/CTRL/ALT) + one digit/letter/mouse-token. "S1"→"SHIFT-1",
-- "CQ"→"CTRL-Q", "AV"→"ALT-V", "Z"→"Z". Mouse tokens expand: "M4"→"BUTTON4",
-- "SM3"→"SHIFT-BUTTON3", "SMU"→"SHIFT-MOUSEWHEELUP". Mouse buttons M3/M4/M5 =
-- middle/side1/side2 (BUTTON3/4/5); MU/MD = wheel up/down (only ever modified —
-- bare wheel is reserved for camera zoom, so the seed only uses S/C/A + MU/MD).
local MODIFIER = { S = "SHIFT-", C = "CTRL-", A = "ALT-" }
local MOUSE = {
  M3 = "BUTTON3", M4 = "BUTTON4", M5 = "BUTTON5",
  MU = "MOUSEWHEELUP", MD = "MOUSEWHEELDOWN",
}
local function normKey(kb)
  if not kb or kb == "" then return nil end
  local pre = MODIFIER[kb:sub(1, 1)]
  local rest = (#kb > 1 and pre) and kb:sub(2) or kb
  local prefix = (rest ~= kb) and pre or ""
  return prefix .. (MOUSE[rest] or rest)
end

-- ---------------------------------------------------------------------------
-- Spec detection
-- ---------------------------------------------------------------------------

-- Build "<Class>/<Spec>" from the class token + (optional) spec name and confirm
-- it exists in the seed. Returns the seed key, or nil if unknown.
function Dump.ResolveSpec(classToken, specName)
  if not classToken then
    local _, ct = UnitClass("player")
    classToken = ct
  end
  local className = CLASS_DISPLAY[classToken] or classToken
  if not specName then
    local idx = GetSpecialization and GetSpecialization()
    if idx then
      specName = select(2, GetSpecializationInfo(idx))
    end
  end
  if className and specName then
    local key = className .. "/" .. specName
    if ns.SEED and ns.SEED.specs[key] then
      return key
    end
  end
  return nil
end

-- Sorted seed keys, optionally filtered to one class (by token or display name).
function Dump.AvailableKeys(classToken)
  local className = classToken and (CLASS_DISPLAY[classToken] or classToken)
  local prefix = className and (className .. "/")
  local keys = {}
  if ns.SEED then
    for k in pairs(ns.SEED.specs) do
      if not prefix or k:sub(1, #prefix) == prefix then
        keys[#keys + 1] = k
      end
    end
  end
  table.sort(keys)
  return keys
end

-- Resolve a slash-command argument to a seed key.
--   nil/""            → detect the current spec
--   "Frost"           → current class + that spec (case-insensitive)
--   "Mage Fire" / "Mage/Fire" → explicit class + spec
-- Returns nil if nothing matches.
function Dump.Resolve(input)
  local _, ct = UnitClass("player")
  if not input or input == "" then
    return Dump.ResolveSpec(ct, nil)
  end
  local target = input:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""):lower()
  local curClass = (CLASS_DISPLAY[ct] or ""):lower()
  local bare
  for _, k in ipairs(Dump.AvailableKeys()) do
    local cp, sp = k:match("^(.*)/(.*)$")
    local lc, ls = cp:lower(), sp:lower()
    if target == lc .. "/" .. ls or target == lc .. " " .. ls then
      return k
    end
    if target == ls then
      if lc == curClass then return k end -- bare spec: current class wins
      bare = bare or k
    end
  end
  return bare
end

-- ---------------------------------------------------------------------------
-- Runtime spell-ID resolution (authoritative; no IDs baked into Data.lua)
-- ---------------------------------------------------------------------------

-- Lazy name→spellID map built from the player's own spellbook — the fallback
-- for names C_Spell.GetSpellInfo won't resolve, and a drift catcher. Rebuilt
-- per dump (learnable set changes with spec/talents).
local function buildSpellbookMap()
  local map = {}
  local ok = pcall(function()
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return end
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
      local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
      if info and info.itemIndexOffset and info.numSpellBookItems then
        for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
          local item = C_SpellBook.GetSpellBookItemInfo(i, bank)
          if item and item.spellID and item.name then
            map[item.name] = item.spellID
          end
        end
      end
    end
  end)
  if not ok then return {} end
  return map
end

-- Seed name → correct spell name, for typos / Midnight renames the seed carries
-- from the volatile Bellular sheet (which we can't hand-edit — Data.lua is
-- generated). Non-destructive drift fix; keep in sync with check_seed_spells.py
-- findings. ("Efflorescence?" is a literal '?' typo in the source workbook.)
local ALIASES = {
  ["Efflorescence?"] = "Efflorescence",
}

-- Collapse a talented/transient override to its BASE spell. Two jobs:
--   1) resolution — `C_Spell.GetSpellInfo(name)` follows whatever override is
--      live *at that instant*, so "Hand of Gul'dan" resolves to Ruination while
--      the Diabolist Pit Lord art is armed, and "Grimoire: Fel Ravager" to
--      Devour Magic while the grimoire is on cooldown. Placing that transient
--      ID bakes a momentary state onto the bar — the button then shows a spell
--      that is dead most of the time, which reads in-game as "the ability never
--      got bound". Always place the base; the game re-applies the override on
--      the button by itself.
--   2) comparison — so a placed override and its spellbook base count as one.
-- Falls back to the id if the API is unavailable.
local function normID(id)
  if not id then return nil end
  local base = FindBaseSpellByID and FindBaseSpellByID(id)
  return base or id
end

-- name → base spellID (or nil). Placeholder labels and unknown/untalented names
-- return nil so the caller reports them cleanly instead of placing a wrong spell.
local function resolveSpellID(name, sbMap)
  if not name or PLACEHOLDER[name] then return nil end
  name = ALIASES[name] or name
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID then return normID(info.spellID) end
  end
  return normID(sbMap and sbMap[name] or nil)
end

-- ---------------------------------------------------------------------------
-- Placement (guarded pickup→place idiom from Snapshot.applyActions)
-- ---------------------------------------------------------------------------

-- Only place if the pickup actually loaded the cursor; assert slot bounds.
-- Returns true on a real placement.
local function placeSpell(id, absSlot)
  if not id or absSlot < 1 or absSlot > 180 then return false end
  ClearCursor()
  C_Spell.PickupSpell(id)
  if GetCursorInfo() then
    PlaceAction(absSlot)
    ClearCursor()
    return true
  end
  ClearCursor()
  return false
end

local function clearSlot(absSlot)
  if absSlot >= 1 and absSlot <= 180 and GetActionInfo(absSlot) then
    PickupAction(absSlot)
    ClearCursor()
  end
end

-- ---------------------------------------------------------------------------
-- The dump
-- ---------------------------------------------------------------------------

function Dump.Run(seedKey, opts)
  opts = opts or {}
  local spec = ns.SEED and ns.SEED.specs[seedKey]
  if not spec then
    ns.Emit(ERR .. "BucketBinds" .. R .. ": unknown spec '" .. tostring(seedKey) .. "'.")
    return
  end

  -- Combat guard: can't touch bindings/actions in lockdown. Defer the whole
  -- dump (auto-backup included) to PLAYER_REGEN_ENABLED via the shared queue.
  if InCombatLockdown() then
    if ns.QueueAction then ns.QueueAction(function() Dump.Run(seedKey, opts) end) end
    say("in combat — dump deferred until you leave combat.")
    return "deferred"
  end

  -- Auto-backup so /bb undo reverts the dump (free M1 reuse).
  BucketBindsDB.autobackup = ns.Snapshot.Capture()

  -- Ensure all 5 stock bars are visible, else placed abilities are invisible.
  -- (Edit Mode governs final visibility; the smoke test confirms.)
  if SetActionBarToggles then SetActionBarToggles(1, 1, 1, 1, 1) end

  local _, classToken = UnitClass("player")
  local formOffsets = FORM_BONUS_BARS[classToken]
  local sbMap = buildSpellbookMap()

  -- 1) Enumerate the managed slots (40 base + mirrored bar-1 form slots) and
  --    clear them so stale content from a previous dump / the player doesn't
  --    linger where this spec places nothing.
  for _, b in ipairs(ns.SEED.buckets) do
    if b.bar and BAR_MAP[b.bar] then
      clearSlot(BAR_MAP[b.bar].base + (b.slot - 1))
      if b.bar == 1 and formOffsets then
        for _, off in ipairs(formOffsets) do
          clearSlot(1 + (5 + off) * 12 + (b.slot - 1))
        end
      end
    end
  end

  -- 2) Place + bind each spell bucket; mirror bar 1 onto the form bars.
  -- opts.noBind (from `/bb dump ... --nobind`): place abilities on the bars but
  -- leave the player's existing keybindings untouched — no SetBinding, no
  -- SaveBindings. Placement, form-mirror, and the auto-backup/undo still apply.
  local placed, applicable, bound, formMirrored = 0, 0, 0, 0
  local unresolved, skippedM5, bar1IDs = {}, {}, {}

  for _, b in ipairs(ns.SEED.buckets) do
    if b.bar and BAR_MAP[b.bar] then
      local name = spec[b.category]
      local id = resolveSpellID(name, sbMap)
      local absSlot = BAR_MAP[b.bar].base + (b.slot - 1)

      if name and not PLACEHOLDER[name] then
        applicable = applicable + 1
        if id and placeSpell(id, absSlot) then
          placed = placed + 1
        else
          unresolved[#unresolved + 1] = name
        end
      elseif name and PLACEHOLDER[name] then
        -- placeholder on a real bar (Alt-bar item/trinket/racial macros, Mount).
        -- Categories the M5 macro post-pass fully handles drop off the skip list.
        if not (ns.Macros and ns.Macros.HANDLED_CATEGORIES[b.category]) then
          skippedM5[b.category] = true
        end
      end
      -- (name == nil → this spec doesn't use the bucket; silent, not an error)

      -- Bind the key→slot layer (unless --nobind): stable even when the slot is
      -- momentarily empty (untalented ability the player may spec into later).
      if not opts.noBind then
        local cmd = BAR_MAP[b.bar].prefix .. b.slot
        -- Free any keys currently bound to this managed slot before setting the
        -- seed key, so relocating a bucket (e.g. Personal Defensive 1 from Z to
        -- BUTTON5) actually vacates the old key instead of leaving it as a stale
        -- duplicate binding. Enforces the layout's 1:1 "one key per managed slot".
        local k1, k2 = GetBindingKey(cmd)
        if k1 then SetBinding(k1) end
        if k2 then SetBinding(k2) end
        local key = normKey(b.keybind)
        if key and SetBinding(key, cmd) then
          bound = bound + 1
        end
      end

      -- Mirror the paging main bar onto every form bonus bar.
      if b.bar == 1 then
        bar1IDs[b.slot] = id
        if id and formOffsets then
          for _, off in ipairs(formOffsets) do
            if placeSpell(id, 1 + (5 + off) * 12 + (b.slot - 1)) then
              formMirrored = formMirrored + 1
            end
          end
        end
      end
    elseif b.category then
      skippedM5[b.category] = true -- bar=None bucket (Stance) → M5 stance work
    end
  end

  -- Contextual bar (pet OR stance) → ALT+1..8. These aren't action slots — they
  -- are their own binding namespaces (BONUSACTIONBUTTON / SHAPESHIFTBUTTON) that
  -- the game auto-populates, so we only bind, never place. A class has a pet bar
  -- OR a stance bar (never both), detected at runtime: shapeshift forms win, else
  -- a pet class. ALT+N the active bar doesn't fill is cleared, so this row is
  -- owned wholesale by the contextual bar (was Trinket/Racial/Free, now vacated).
  -- @verify-ingame: 12.0.7 command names + per-class button counts.
  local ctxMsg
  if not opts.noBind then
    local forms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
    local prefix, n
    if forms > 0 then
      prefix, n = "SHAPESHIFTBUTTON", math.min(forms, 8)
      ctxMsg = ("ALT+1–%d → stance/form bar"):format(n)
    elseif PET_CLASS[classToken] then
      prefix, n = "BONUSACTIONBUTTON", 8
      ctxMsg = "ALT+1–8 → pet bar"
    else
      ctxMsg = "ALT+1–8 left free (no pet/stance bar for this class)"
    end
    for i = 1, 8 do
      if prefix and i <= n then
        SetBinding("ALT-" .. i, prefix .. i)
      else
        SetBinding("ALT-" .. i) -- clear: this row belongs to the contextual bar
      end
    end
  end

  -- M5 macro post-pass (Phase A): overwrite slot 12's raw interrupt with the
  -- smart focus-interrupt macro, and place + bind the set-focus macro on key 5.
  -- Runs BEFORE the lastDump stash so Apply can nil bar1IDs[12] (see Hazard 1:
  -- otherwise onShapeshift re-places the raw interrupt over the macro on form
  -- entry). formOffsets and bar1IDs are already locals here.
  local macroRep
  if ns.Macros then
    macroRep = ns.Macros.Apply(seedKey, {
      fromDump = true, formOffsets = formOffsets, bar1IDs = bar1IDs, noBind = opts.noBind })
  end

  -- Persist the bindings once (skipped under --nobind), and stash the bar-1
  -- layout for the self-healing shapeshift hook.
  if not opts.noBind then SaveBindings(GetCurrentBindingSet()) end
  BucketBindsDB.lastDump = { classToken = classToken, bar1 = bar1IDs }

  -- 3) Report — never silent.
  say("dumped %s — %d/%d abilities placed, %s.", seedKey, placed, applicable,
    opts.noBind and "bindings left unchanged (--nobind)"
      or (bound .. " bound"))
  if formOffsets and formMirrored > 0 then
    say("  (%d form-mirrored)", formMirrored)
  end
  if ctxMsg then say("  %s", ctxMsg) end
  if #unresolved > 0 then
    say(WARN .. "unresolved (%d): %s" .. R, #unresolved, table.concat(unresolved, ", "))
  end
  local m5 = {}
  for cat in pairs(skippedM5) do m5[#m5 + 1] = cat end
  if #m5 > 0 then
    table.sort(m5)
    say(WARN .. "skipped (M5 — items/macros/stances): %s" .. R, table.concat(m5, ", "))
  end
  if macroRep then
    say("  macros: %d created, %d updated%s", macroRep.created, macroRep.edited,
      macroRep.capped > 0 and (WARN .. " (out of slots!)" .. R) or "")
    if macroRep.intrSkipped then
      say("  no interrupt for this spec — slot V left as placed.")
    end
    say("  items: %d placed%s (trinket→6, racial→%s); prep: flask→8%s, buff→9%s",
      macroRep.itemsPlaced, macroRep.itemsCapped > 0 and (WARN .. " (capped!)" .. R) or "",
      macroRep.racialSkipped and (WARN .. "skipped" .. R) or "7",
      macroRep.flaskPlaced and "" or (WARN .. " (not placed)" .. R),
      macroRep.buffSkipped and (WARN .. " skipped" .. R)
        or (macroRep.buffPlaced and "" or (WARN .. " (not placed)" .. R)))
  end
  say("not what you wanted? " .. "/bb undo" .. " reverts this dump.")
  return "applied"
end

-- ---------------------------------------------------------------------------
-- M3 spillover: surface learned-but-unplaced abilities on a reserve region
-- ---------------------------------------------------------------------------

-- Reserved spill region: the modern extra action bars (Edit Mode "Action Bar 6"
-- and "Action Bar 7" = MultiBar5/6). These absolute slot IDs are BEST-EFFORT
-- and flagged for in-game verification — the 133–180 range has shifted across
-- expansions. Spill sets NO keybinds, so a wrong base only mis-places (still
-- visible), never mis-binds. Placement is defensive (empty slots only), so a
-- wrong guess can't clobber real bars.
-- @verify-ingame: confirm slots 145–168 map to Action Bars 6–7. In-game:
--   /run for i=133,180 do local t,id=GetActionInfo(i); if t then print(i,t,id) end end
local SPILL_BASE, SPILL_COUNT = 145, 24

-- (normID lives above, next to resolveSpellID — it's part of resolution now.)

-- Every learned, castable, active-spec spell as {id, name}. Skips passives and
-- non-Spell book entries (FutureSpell / Flyout / PetAction).
local function enumerateCastable()
  local out = {}
  pcall(function()
    if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return end
    local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
    local SPELL = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
    for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
      local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
      -- Skip inactive-spec skill lines (offSpecID set = a spec you're not in);
      -- their spells sit in the book but aren't castable right now.
      if info and info.itemIndexOffset and info.numSpellBookItems
         and (not info.offSpecID or info.offSpecID == 0) then
        for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
          local it = C_SpellBook.GetSpellBookItemInfo(i, bank)
          if it and it.spellID and it.name and not it.isPassive and not it.isOffSpec
             and (SPELL == nil or it.itemType == SPELL) then
            out[#out + 1] = { id = it.spellID, name = it.name }
          end
        end
      end
    end
  end)
  return out
end

-- Absolute slots 1–144 hold every "real" bar (bars 1–6 pages + form/stance
-- bonus bars); collect the spells sitting there, normalized. This is the
-- ground-truth "already on a bar" set — includes the dump AND manual placements.
local function placedSpellSet()
  local set = {}
  for slot = 1, 144 do
    local t, id = GetActionInfo(slot)
    if t == "spell" and id then set[normID(id)] = true end
  end
  return set
end

-- Noise both the overflow ring and spill suppress — auto-attack, wand Shoot,
-- battle-pet management, etc. The seed's excludeSpells table is keyed by spellID
-- (raw and/or base) and/or exact name; check all three so a talented override or
-- a name-only entry still matches.
local function isExcluded(id, base, name)
  local ex = ns.SEED and ns.SEED.excludeSpells
  if not ex then return false end
  return (ex[id] or (base and ex[base]) or (name and ex[name])) and true or false
end

-- /bb spill [clear]. Enumerate the active spellbook, subtract what's already on
-- a bar (override-normalized) and the excludeSpells noise, and drop the remainder
-- onto the reserve region — no keybinds; the payoff is visibility + live QA of the
-- seed. Combat-gated.
function Dump.Spill(opts)
  opts = opts or {}
  if InCombatLockdown() then
    if ns.QueueAction then ns.QueueAction(function() Dump.Spill(opts) end) end
    say("in combat — spill deferred until you leave combat.")
    return "deferred"
  end

  BucketBindsDB.spillSlots = BucketBindsDB.spillSlots or {}

  -- 'clear' subcommand: empty only the slots WE filled, never foreign content.
  if opts.clear then
    local n = 0
    for _, slot in ipairs(BucketBindsDB.spillSlots) do
      if GetActionInfo(slot) then clearSlot(slot); n = n + 1 end
    end
    BucketBindsDB.spillSlots = {}
    say("cleared %d spilled slot(s).", n)
    return "cleared"
  end

  if SetActionBarToggles then SetActionBarToggles(1, 1, 1, 1, 1) end

  -- Clear our previous spill first so a re-run is idempotent — but only OUR
  -- slots, so we never wipe abilities the player parked on these bars.
  for _, slot in ipairs(BucketBindsDB.spillSlots) do clearSlot(slot) end
  BucketBindsDB.spillSlots = {}

  local placed = placedSpellSet()

  -- Candidates = learned castable spells not already on a bar, de-duped by base.
  local seen, candidates = {}, {}
  for _, s in ipairs(enumerateCastable()) do
    local key = normID(s.id)
    if key and not placed[key] and not seen[key]
       and not isExcluded(s.id, key, s.name) then
      seen[key] = true
      candidates[#candidates + 1] = s
    end
  end
  table.sort(candidates, function(a, b) return a.name < b.name end)

  -- Free slots in the reserve region (defensive: skip any foreign content).
  local free = {}
  for i = 0, SPILL_COUNT - 1 do
    local slot = SPILL_BASE + i
    if slot <= 180 and not GetActionInfo(slot) then free[#free + 1] = slot end
  end

  local fi, placedNames, overflow = 1, {}, {}
  for _, s in ipairs(candidates) do
    local slot = free[fi]
    if slot and placeSpell(s.id, slot) then
      BucketBindsDB.spillSlots[#BucketBindsDB.spillSlots + 1] = slot
      placedNames[#placedNames + 1] = ("%s (%d)"):format(s.name, s.id)
      fi = fi + 1
    else
      overflow[#overflow + 1] = ("%s (%d)"):format(s.name, s.id)
    end
  end

  say("spilled %d unplaced abilit%s onto the reserve bars.", #placedNames,
    #placedNames == 1 and "y" or "ies")
  if #placedNames > 0 then say("  %s", table.concat(placedNames, ", ")) end
  if #overflow > 0 then
    say(WARN .. "%d didn't fit (%d-slot region full) — listed, not dropped: %s" .. R,
      #overflow, SPILL_COUNT, table.concat(overflow, ", "))
  end
  say("clear them with " .. "/bb spill clear" .. ".")
  return "applied"
end

-- ---------------------------------------------------------------------------
-- /bb ring [clear]: hand the overflow set to OPie as one addon-owned ring
-- ---------------------------------------------------------------------------

-- Same computed set as /bb spill (castable, learned, not on a bar, not excluded),
-- but the destination is an OPie radial instead of the reserve bars. Uses OPie's
-- public CustomRings:SetExternalRing (runtime-callable, addon-owned) — so the ring
-- is regenerated per spec on demand, not user-edited. No bars, no keybinds, and no
-- combat guard (building a ring is not a protected action). No-ops cleanly when
-- OPie isn't loaded (declared ## OptionalDeps: OPie).
-- @verify-ingame: confirm SetExternalRing accepts bare {id=<spellID>} slices and
-- that our _u tokens don't collide with OPie's own; adjust to macrotext
-- ("/cast {{spell:<id>}}") slices if bare spell ids don't resolve.
local RING_NAME = "BB_Overflow"

function Dump.Ring(opts)
  opts = opts or {}
  local CR = OPie and OPie.CustomRings
  if not (CR and CR.SetExternalRing) then
    say(WARN .. "OPie not detected — /bb ring needs OPie (its CustomRings API) loaded." .. R)
    return "no-opie"
  end

  if opts.clear then
    CR:SetExternalRing(RING_NAME, false) -- false retires the ring
    say("removed the OPie overflow ring.")
    return "cleared"
  end

  local placed = placedSpellSet()
  local seen, cand = {}, {}
  for _, s in ipairs(enumerateCastable()) do
    local key = normID(s.id)
    if key and not placed[key] and not seen[key]
       and not isExcluded(s.id, key, s.name) then
      seen[key] = true
      cand[#cand + 1] = { id = s.id, key = key, name = s.name }
    end
  end
  table.sort(cand, function(a, b) return a.name < b.name end)

  if #cand == 0 then
    CR:SetExternalRing(RING_NAME, false)
    say("overflow ring empty (nothing castable is unplaced + non-excluded) — ring cleared.")
    return "empty"
  end

  -- Ring descriptor = array of slices + named ring fields. Each slice's _u token
  -- is derived from the base spellID so re-runs reproduce identical tokens
  -- (idempotent update-in-place; OPie hard-errors on duplicate/missing tokens).
  local desc = { name = "Overflow", _u = "BBov", v = 1 }
  for _, c in ipairs(cand) do
    desc[#desc + 1] = { id = c.id, _u = "s" .. c.key }
  end
  CR:SetExternalRing(RING_NAME, desc)

  say("built OPie overflow ring with %d abilit%s — bind its open-key in OPie's options.",
    #cand, #cand == 1 and "y" or "ies")
  return "ok"
end

-- ---------------------------------------------------------------------------
-- /bb test: minimal place+bind smoke test (no full dump)
-- ---------------------------------------------------------------------------

-- Recuperate — a universal level-90 Midnight ability every character learns —
-- is the probe spell. Placed on bar 5 button 12 (abs slot 48 — unused; the M5
-- macro engine now owns button 1 / slot 37 for the set-focus macro on key 5)
-- with a known-good binding command, and bound to ALT-0 (rarely used).
-- Non-destructive: captures + restores whatever it displaces via /bb test clear.
local TEST_SPELL = 1231418            -- Recuperate
local TEST_SLOT  = 48                 -- MULTIACTIONBAR4BUTTON12 (bar 5 button 12, unused)
local TEST_CMD   = "MULTIACTIONBAR4BUTTON12"
local TEST_KEY   = "ALT-0"

function Dump.Test(opts)
  opts = opts or {}
  if InCombatLockdown() then
    if ns.QueueAction then ns.QueueAction(function() Dump.Test(opts) end) end
    say("in combat — test deferred until you leave combat.")
    return "deferred"
  end

  -- 'clear' subcommand: restore whatever the test displaced.
  if opts.clear then
    local prev = BucketBindsDB.testBackup
    if not prev then say("nothing to clear (no test run yet)."); return end
    clearSlot(TEST_SLOT)
    if prev.action then placeSpell(prev.action, TEST_SLOT) end
    SetBinding(TEST_KEY, prev.binding) -- prev.binding nil → unbinds the key
    SaveBindings(GetCurrentBindingSet())
    BucketBindsDB.testBackup = nil
    say("test reverted — slot %d and %s restored.", TEST_SLOT, TEST_KEY)
    return "cleared"
  end

  -- Probe spell: Recuperate — resolved the authoritative way, by NAME in your
  -- own spellbook (like the dump does), which also catches a talented override
  -- of the base ID. IsPlayerSpell(baseID) can be false for such spells, so we
  -- don't gate on it. Fallbacks: the raw ID, then any real castable spell —
  -- Auto Attack (6603) is excluded so the probe is a genuine ability.
  local AUTO_ATTACK = 6603
  local sbMap = buildSpellbookMap()
  local baseInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(TEST_SPELL)
  local wantName = (baseInfo and baseInfo.name) or "Recuperate"

  local id = sbMap[wantName] or sbMap["Recuperate"]
  if not id and IsPlayerSpell and IsPlayerSpell(TEST_SPELL) then
    id = TEST_SPELL
  end
  if not id then
    for _, s in ipairs(enumerateCastable()) do
      if s.id ~= AUTO_ATTACK then id = s.id; break end
    end
  end
  if not id then
    say(WARN .. "no castable spell found to test with." .. R)
    return
  end
  local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
  local name = (info and info.name) or ("spell " .. id)

  if SetActionBarToggles then SetActionBarToggles(1, 1, 1, 1, 1) end

  -- Back up what we're about to displace (non-destructive).
  local pt, pid = GetActionInfo(TEST_SLOT)
  local prevBind = GetBindingAction and GetBindingAction(TEST_KEY)
  BucketBindsDB.testBackup = {
    action  = (pt == "spell") and pid or nil,
    binding = (prevBind and prevBind ~= "") and prevBind or nil,
  }

  clearSlot(TEST_SLOT)
  local okPlace = placeSpell(id, TEST_SLOT)
  local okBind  = SetBinding(TEST_KEY, TEST_CMD) and true or false
  if okBind then SaveBindings(GetCurrentBindingSet()) end

  say("test — place %s on slot %d: %s; bind %s→%s: %s.", name, TEST_SLOT,
    okPlace and "OK" or ERR .. "FAIL" .. R, TEST_KEY, TEST_CMD,
    okBind and "OK" or ERR .. "FAIL" .. R)
  if okPlace and okBind then
    say("press " .. TEST_KEY .. " to fire it; revert with " .. "/bb test clear" .. ".")
  else
    say(WARN .. "the write path isn't fully working on this character/patch." .. R)
  end
  return "applied"
end

-- ---------------------------------------------------------------------------
-- /bb diagnostics: honest, machine-readable resolution + placement report
-- ---------------------------------------------------------------------------

-- Turns "some abilities don't show up after a dump" into a concrete report. For
-- the ACTIVE spec it classifies every seed bucket (unresolved / resolved-known /
-- resolved-unknown / placeholder), reads the live bars back to see which
-- resolved-known abilities actually landed, and lists castable abilities no seed
-- bucket covers ("the gaps"). The result is written into
-- BucketBindsDB.diagnostics[<char>][<spec>].
--
-- Storage accumulates: BucketBindsDB is ACCOUNT-level SavedVariables (one file
-- shared by every character), so each run MERGES into its char/spec slot and
-- never wipes the table — run all 3 specs of a character, hop to another, and
-- all reports collect in one BucketBinds.lua. SavedVariables only flush to disk
-- on /reload or logout, so the user reloads once per character before the
-- wowkb.diagnostics reader can parse them off the WSL mount.
--
-- READ-ONLY: unlike Dump.Run/Spill/Test it touches NO protected API (no
-- PlaceAction / SetBinding / PickupSpell / SetActionBarToggles) — only
-- unprotected reads plus a saved-variable write — so it needs no
-- InCombatLockdown() guard and is safe to run mid-fight to inspect a dump.
function Dump.Diagnostics(opts)
  opts = opts or {}
  BucketBindsDB.diagnostics = BucketBindsDB.diagnostics or {}

  -- 'clear' subcommand: wipe the whole store (stale-entry cleanup).
  if opts.clear then
    local n = 0
    for _, byChar in pairs(BucketBindsDB.diagnostics) do
      for _ in pairs(byChar) do n = n + 1 end
    end
    BucketBindsDB.diagnostics = {}
    say("cleared %d stored diagnostics report(s).", n)
    return "cleared"
  end

  -- Identity + active spec. GetSpecialization() can be nil for a beat right
  -- after a spec swap — bail rather than write a half-report.
  local charName = UnitName("player") or "?"
  local realm = (GetRealmName and GetRealmName() or "?"):gsub("%s+", "")
  local charKey = charName .. "-" .. realm
  local _, classToken = UnitClass("player")
  local classDisplay = CLASS_DISPLAY[classToken] or classToken or "?"

  local specIdx = GetSpecialization and GetSpecialization()
  if not specIdx then
    say(WARN .. "no active specialization detected (mid-swap?) — try again in a moment." .. R)
    return
  end
  local specID, specName = GetSpecializationInfo(specIdx)
  specName = specName or ("spec " .. tostring(specIdx))

  local seedKey = Dump.ResolveSpec(classToken, specName)
  local spec = seedKey and ns.SEED and ns.SEED.specs[seedKey] or nil

  -- Precompute the castable/known model once (same helpers the dump uses).
  local sbMap = buildSpellbookMap()
  local castable = enumerateCastable()
  local castByNorm, castByName = {}, {}
  for _, s in ipairs(castable) do
    local nk = normID(s.id)
    if nk then castByNorm[nk] = s end
    castByName[s.name] = s.id
  end

  local report = {
    meta = {
      time = time and time() or 0,
      char = charKey,
      classToken = classToken,
      classDisplay = classDisplay,
      specID = specID,
      specName = specName,
      seedKey = seedKey,
      addonVersion = (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "?",
      interface = select(4, GetBuildInfo()),
      build = (GetBuildInfo()),
    },
    summary = {
      castableTotal = #castable, seedPlaceable = 0, resolvedKnown = 0,
      resolvedUnknown = 0, unresolved = 0, placeholders = 0,
      onBar = 0, placementIssues = 0, unmapped = 0,
    },
    buckets = {},
    unmapped = {},
    placementIssues = {},
  }
  local S = report.summary
  local seedMapped = {} -- normID → true for every resolvable bucket (known or not)

  if spec then
    for _, b in ipairs(ns.SEED.buckets) do
      -- In Data.lua bar/slot are numbers, so no tonumber (matches Dump.Run).
      if type(b.bar) == "number" and BAR_MAP[b.bar] then
        local name = spec[b.category]
        if name ~= nil then -- name == nil → this spec doesn't use the bucket
          local class, id, nk, known
          if PLACEHOLDER[name] then
            class = "placeholder"
            S.placeholders = S.placeholders + 1
          else
            S.seedPlaceable = S.seedPlaceable + 1
            id = resolveSpellID(name, sbMap)
            if id == nil then
              -- GetSpellInfo resolves ANY client-known name; nil = the seed
              -- string is wrong → a seed drift/typo BUG.
              class = "unresolved"
              S.unresolved = S.unresolved + 1
            else
              nk = normID(id)
              seedMapped[nk] = true
              -- Spellbook membership (by NAME and by normID) is the primary
              -- "known" signal — it's the only one that handles talented
              -- overrides. IsPlayerSpell/IsSpellKnown are corroborating only.
              known = (castByName[name] ~= nil)
                or (nk ~= nil and castByNorm[nk] ~= nil)
                or (IsPlayerSpell and IsPlayerSpell(id))
                or (IsSpellKnown and IsSpellKnown(id)) or false
              known = known and true or false
              if known then
                class = "resolved-known"
                S.resolvedKnown = S.resolvedKnown + 1
              else
                class = "resolved-unknown" -- untalented / not learned (expected)
                S.resolvedUnknown = S.resolvedUnknown + 1
              end
            end
          end

          local absSlot = BAR_MAP[b.bar].base + (b.slot - 1)
          local rec = {
            category = b.category, bar = b.bar, slot = b.slot, absSlot = absSlot,
            key = normKey(b.keybind), name = name, class = class,
            spellID = id, normID = nk, known = known,
          }
          report.buckets[#report.buckets + 1] = rec

          -- Placement read-back for resolved-known buckets only (the ones that
          -- SHOULD have landed on a bar). Compare via normID on both sides.
          if class == "resolved-known" then
            local at, aid = GetActionInfo(absSlot)
            local issue
            if not at then
              issue = "empty"
            elseif at ~= "spell" then
              issue = "wrong-type"
            elseif normID(aid) ~= nk then
              issue = "wrong-spell"
            end
            if issue then
              S.placementIssues = S.placementIssues + 1
              local aname
              if aid and C_Spell and C_Spell.GetSpellInfo then
                local ai = C_Spell.GetSpellInfo(aid)
                aname = ai and ai.name
              end
              report.placementIssues[#report.placementIssues + 1] = {
                category = b.category, absSlot = absSlot,
                intendedID = id, intendedName = name,
                issue = issue, actualType = at, actualID = aid, actualName = aname,
              }
            else
              S.onBar = S.onBar + 1
            end

            -- Secondary: probe the form/stance mirror slots (own sub-field, NOT
            -- in the main count) so we can see if bar-1 mirroring landed too.
            if b.bar == 1 then
              local offsets = FORM_BONUS_BARS[classToken]
              if offsets then
                local mirror = {}
                for _, off in ipairs(offsets) do
                  local ms = 1 + (5 + off) * 12 + (b.slot - 1)
                  local mt, mid = GetActionInfo(ms)
                  mirror[#mirror + 1] = {
                    absSlot = ms,
                    ok = (mt == "spell" and normID(mid) == nk) and true or false,
                  }
                end
                rec.formMirror = mirror
              end
            end
          end
        end
      end
    end
  end

  -- Unmapped ("the gaps"): castable spells no resolvable seed bucket covers,
  -- deduped by normID, sorted by name. Same pattern as Dump.Spill but
  -- subtracting the seed-model set instead of the current bar state (so like
  -- Spill it does NOT filter Auto-Attack/professions — those legitimately are
  -- castable-and-unmapped).
  local seen, unmapped = {}, {}
  for _, s in ipairs(castable) do
    local nk = normID(s.id)
    if nk and not seedMapped[nk] and not seen[nk] then
      seen[nk] = true
      unmapped[#unmapped + 1] = { id = s.id, name = s.name }
    end
  end
  table.sort(unmapped, function(a, b) return a.name < b.name end)
  report.unmapped = unmapped
  S.unmapped = #unmapped

  -- Accumulate into diagnostics[charKey][specName] (merge, never wipe).
  local byChar = BucketBindsDB.diagnostics[charKey] or {}
  byChar[specName] = report
  BucketBindsDB.diagnostics[charKey] = byChar

  -- Chat summary.
  if not spec then
    say("no seed for %s/%s — recorded castableTotal=%d, %d unmapped (all castable), empty buckets.",
      classDisplay, specName, S.castableTotal, S.unmapped)
  else
    say("diagnostics %s / %s — %d castable; seed: %d known / %d untalented / %d unresolved / %d placeholder; %d on-bar, %d placement issue(s), %d unmapped.",
      charKey, specName, S.castableTotal, S.resolvedKnown, S.resolvedUnknown,
      S.unresolved, S.placeholders, S.onBar, S.placementIssues, S.unmapped)
  end
  if S.unresolved > 0 then
    local names = {}
    for _, bk in ipairs(report.buckets) do
      if bk.class == "unresolved" then names[#names + 1] = bk.name end
    end
    say(WARN .. "unresolved seed names (%d — likely seed bugs): %s" .. R,
      S.unresolved, table.concat(names, ", "))
  end
  if S.placementIssues > 0 then
    local its = {}
    for _, pi in ipairs(report.placementIssues) do
      its[#its + 1] = ("%s (%s)"):format(pi.category, pi.issue)
    end
    say(WARN .. "placement issues (%d): %s" .. R, S.placementIssues, table.concat(its, ", "))
  end

  -- Footer: how many reports are now stored + the next step.
  local nChar, nReports = 0, 0
  for _, bc in pairs(BucketBindsDB.diagnostics) do
    nChar = nChar + 1
    for _ in pairs(bc) do nReports = nReports + 1 end
  end
  say("%d report(s) across %d character(s) stored. /reload, then run: uv run python -m wowkb.diagnostics",
    nReports, nChar)
  return "recorded"
end

-- ---------------------------------------------------------------------------
-- Self-healing form mirror
-- ---------------------------------------------------------------------------

-- FORM_BONUS_BARS is best-effort; modern retail may page a form to a bonus bar
-- the table didn't list (Warrior/Priest are uncertain in 12.0.x). When the
-- player enters a form after a dump and that form's bar-1 slots are empty,
-- mirror the stored bar-1 layout onto the live GetBonusBarOffset() range.
-- Out-of-combat only (PlaceAction is protected); the common first-entry case is
-- typically out of combat, and the static table covers the in-combat cases.
local function onShapeshift()
  local dump = BucketBindsDB and BucketBindsDB.lastDump
  if not dump or not dump.bar1 or InCombatLockdown() then return end
  local offset = GetBonusBarOffset and GetBonusBarOffset()
  if not offset or offset <= 0 then return end
  local base = 1 + (5 + offset) * 12
  for s = 1, 12 do -- bar 1 holds 12 buckets (unmod layer); form bars are 12 slots
    local absSlot = base + (s - 1)
    if absSlot >= 1 and absSlot <= 180 and not GetActionInfo(absSlot) then
      placeSpell(dump.bar1[s], absSlot)
    end
  end
end

local shifter = CreateFrame("Frame")
shifter:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
shifter:SetScript("OnEvent", onShapeshift)
