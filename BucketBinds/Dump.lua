-- BucketBinds — Dump: the M2 payoff. Given the player's class+spec, walk the
-- seed's 40 placeable spell buckets, resolve each bucket's ability name to a
-- runtime spell ID, place it on the fixed action slot the bucket owns, mirror
-- the main bar onto each form/stance bonus bar, and set the key→slot binding —
-- a one-shot "here's a complete, ergonomic keybind layout" dump.
--
-- Bar model (decided 2026-07-10): direct modifier binds on all-visible stock
-- bars, no paging. Each (bar, slot) maps 1:1 to one absolute action slot + one
-- SetBinding command; the seed carries the explicit key per combo.
--
-- Combat-gated like Snapshot.Apply (defers via ns.QueueAction). Takes an
-- auto-backup into BucketBindsDB.autobackup first, so /bb undo reverts a dump.
--
-- The 12 bar=None buckets (consumable/trinket/racial macros + Stance/Free) are
-- DEFERRED to M4 and reported as "skipped (M4)", never silently dropped.
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
  print(COLOR .. "BucketBinds" .. R .. ": " .. fmt:format(...))
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

-- Placeholder ability values the seed uses for non-spell buckets. These never
-- resolve to a spell and never count as "unresolved" — they route to the M4
-- skip list (macro/summon generation is a separate milestone).
local PLACEHOLDER = {
  ["Mount"] = true, ["Free"] = true, ["Racial Ability"] = true,
  ["Healthstone/Potion Macro"] = true, ["Drinking/Mana Potion Macro"] = true,
  ["Damage Potion"] = true, ["Another Combat Item If Needed"] = true,
  ["Trinket Macro"] = true,
}

-- keybind notation → SetBinding key string. One optional modifier
-- (S/C/A → SHIFT/CTRL/ALT) + one digit/letter. "S1"→"SHIFT-1", "CQ"→"CTRL-Q",
-- "AV"→"ALT-V", "Z"→"Z".
local MODIFIER = { S = "SHIFT-", C = "CTRL-", A = "ALT-" }
local function normKey(kb)
  if not kb or kb == "" then return nil end
  local pre = MODIFIER[kb:sub(1, 1)]
  if #kb > 1 and pre then
    return pre .. kb:sub(2)
  end
  return kb
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

-- name → spellID (or nil). Placeholder labels and unknown/untalented names
-- return nil so the caller reports them cleanly instead of placing a wrong spell.
local function resolveSpellID(name, sbMap)
  if not name or PLACEHOLDER[name] then return nil end
  name = ALIASES[name] or name
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(name)
    if info and info.spellID then return info.spellID end
  end
  return sbMap and sbMap[name] or nil
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
    print(ERR .. "BucketBinds" .. R .. ": unknown spec '" .. tostring(seedKey) .. "'.")
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
  local placed, applicable, bound, formMirrored = 0, 0, 0, 0
  local unresolved, skippedM4, bar1IDs = {}, {}, {}

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
        skippedM4[b.category] = true -- placeholder sitting on a real bar (Mount)
      end
      -- (name == nil → this spec doesn't use the bucket; silent, not an error)

      -- Bind the key→slot layer regardless: it's stable even when the slot is
      -- momentarily empty (untalented ability the player may spec into later).
      local key = normKey(b.keybind)
      if key and SetBinding(key, BAR_MAP[b.bar].prefix .. b.slot) then
        bound = bound + 1
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
      skippedM4[b.category] = true -- bar=None bucket → M4 (macro/stance work)
    end
  end

  -- Persist the bindings once, and stash the bar-1 layout for the self-healing
  -- shapeshift hook.
  SaveBindings(GetCurrentBindingSet())
  BucketBindsDB.lastDump = { classToken = classToken, bar1 = bar1IDs }

  -- 3) Report — never silent.
  say("dumped %s — %d/%d abilities placed, %d bound%s.", seedKey, placed,
    applicable, bound,
    (formOffsets and formMirrored > 0) and (" (" .. formMirrored .. " form-mirrored)") or "")
  if #unresolved > 0 then
    say(WARN .. "unresolved (%d): %s" .. R, #unresolved, table.concat(unresolved, ", "))
  end
  local m4 = {}
  for cat in pairs(skippedM4) do m4[#m4 + 1] = cat end
  if #m4 > 0 then
    table.sort(m4)
    say(WARN .. "skipped (M4 — items/macros/stances): %s" .. R, table.concat(m4, ", "))
  end
  say("not what you wanted? " .. "/bb undo" .. " reverts this dump.")
  return "applied"
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
  for s = 1, 8 do
    local absSlot = base + (s - 1)
    if absSlot >= 1 and absSlot <= 180 and not GetActionInfo(absSlot) then
      placeSpell(dump.bar1[s], absSlot)
    end
  end
end

local shifter = CreateFrame("Frame")
shifter:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
shifter:SetScript("OnEvent", onShapeshift)
