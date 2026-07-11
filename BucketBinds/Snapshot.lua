-- BucketBinds — Snapshot: transactional capture/restore of keybinds + action
-- bars (slots 1-180) + macros to a named SavedVariables profile.
--
-- Capture is read-only and safe anytime. Apply is combat-gated (auto-defers to
-- PLAYER_REGEN_ENABLED via ns.QueueApply, defined in Core.lua) and takes a
-- single-level auto-backup into BucketBindsDB.autobackup that drives /bb undo.
--
-- Fidelity: bindings = exact mirror, action bars = exact mirror (spell/item/
-- macro restored; mount/pet/flyout/equipmentset captured but skip-and-reported),
-- macros = additive (create/update saved; never delete the user's others).
--
-- All API signatures verified against warcraft.wiki.gg for retail 12.0.x.

local ADDON, ns = ...

local Snapshot = {}
ns.Snapshot = Snapshot

local ACCOUNT_MACRO_CAP = MAX_ACCOUNT_MACROS or 120
local CHARACTER_MACRO_CAP = MAX_CHARACTER_MACROS or 18

local COLOR = "|cff40c0ff"
local WARN = "|cffffd100"
local ERR = "|cffff4040"
local R = "|r"
local function say(fmt, ...)
  print(COLOR .. "BucketBinds" .. R .. ": " .. fmt:format(...))
end

-- ---------------------------------------------------------------------------
-- Capture (read-only)
-- ---------------------------------------------------------------------------

local function captureMeta()
  local name = UnitName("player")
  local realm = GetNormalizedRealmName() or GetRealmName()
  local _, class = UnitClass("player")
  local specIndex = GetSpecialization()
  local specID = specIndex and GetSpecializationInfo(specIndex) or nil
  return {
    created = time(),
    char = (name or "?") .. "-" .. (realm or "?"),
    class = class,
    specID = specID,
    bindingSet = GetCurrentBindingSet(),
  }
end

-- Bindings: enumerate command rows, read the keys currently bound to each.
-- GetBindingKey returns the keys for the *current* binding set, matching the
-- bindingSet we stamp in meta. Header rows / unbound commands drop out (no key).
local function captureBindings()
  local out = {}
  for i = 1, GetNumBindings() do
    local command = GetBinding(i)
    if command and command ~= "" then
      local keys = { GetBindingKey(command) }
      if #keys > 0 then
        out[#out + 1] = { command = command, keys = keys }
      end
    end
  end
  return out
end

-- Action slots 1-180 (covers stance/skyriding bonus bars via absolute IDs —
-- no shapeshifting needed). Macros are stored by name; the numeric index is an
-- unstable position that won't survive a restore.
local function captureActions()
  local out = {}
  for slot = 1, 180 do
    local actionType, id, subType = GetActionInfo(slot)
    if actionType then
      local entry = { slot = slot, type = actionType, id = id, subType = subType }
      if actionType == "macro" and id then
        local name, icon = GetMacroInfo(id)
        entry.name = name
        entry.icon = icon
      end
      out[#out + 1] = entry
    end
  end
  return out
end

-- All macros (account 1..cap, character (cap+1)..). Wholesale capture so any
-- macro-on-bar reference resolves by name at restore time.
local function captureMacros()
  local out = {}
  local numAccount, numChar = GetNumMacros()
  for i = 1, numAccount do
    local name, icon, body = GetMacroInfo(i)
    if name then
      out[#out + 1] = { name = name, body = body, icon = icon, scope = "account" }
    end
  end
  for i = 1, numChar do
    local name, icon, body = GetMacroInfo(ACCOUNT_MACRO_CAP + i)
    if name then
      out[#out + 1] = { name = name, body = body, icon = icon, scope = "char" }
    end
  end
  return out
end

function Snapshot.Capture()
  return {
    meta = captureMeta(),
    bindings = captureBindings(),
    actions = captureActions(),
    macros = captureMacros(),
  }
end

-- ---------------------------------------------------------------------------
-- Apply (combat-gated; run in dependency order: macros -> actions -> bindings)
-- ---------------------------------------------------------------------------

-- Additive: update a same-named macro, else create it, respecting caps. Never
-- deletes the user's other macros. Returns created, edited, skipped counts.
local function applyMacros(macros)
  local created, edited, skipped = 0, 0, 0
  for _, m in ipairs(macros) do
    local idx = m.name and GetMacroIndexByName(m.name) or 0
    if idx and idx > 0 then
      EditMacro(idx, m.name, m.icon, m.body)
      edited = edited + 1
    else
      local perChar = (m.scope == "char")
      local numAccount, numChar = GetNumMacros()
      local room = perChar and (numChar < CHARACTER_MACRO_CAP) or (numAccount < ACCOUNT_MACRO_CAP)
      if room then
        CreateMacro(m.name, m.icon, m.body, perChar)
        created = created + 1
      else
        skipped = skipped + 1
      end
    end
  end
  return created, edited, skipped
end

-- Exact mirror over slots 1-180: place saved content, or clear the slot when
-- the profile had nothing there. Unsupported types / unknown spells are left
-- in place and reported (best-effort). Returns placed, cleared, skipped.
local function applyActions(actions)
  local bySlot = {}
  for _, a in ipairs(actions) do bySlot[a.slot] = a end

  local placed, cleared, skipped = 0, 0, 0
  for slot = 1, 180 do
    local a = bySlot[slot]
    if a then
      ClearCursor()
      local pickedUp = false
      if a.type == "spell" and a.id then
        C_Spell.PickupSpell(a.id)
        pickedUp = true
      elseif a.type == "item" and a.id then
        C_Item.PickupItem(a.id)
        pickedUp = true
      elseif a.type == "macro" and a.name then
        local idx = GetMacroIndexByName(a.name)
        if idx and idx > 0 then
          PickupMacro(idx)
          pickedUp = true
        end
      end
      -- Only place if the pickup actually loaded the cursor (unknown spell /
      -- missing macro leaves it empty); unsupported types never pick up.
      if pickedUp and GetCursorInfo() then
        PlaceAction(slot)
        placed = placed + 1
      else
        skipped = skipped + 1
      end
      ClearCursor()
    elseif GetActionInfo(slot) then
      -- Profile had nothing here but the slot is occupied → clear it.
      PickupAction(slot)
      ClearCursor()
      cleared = cleared + 1
    end
  end
  return placed, cleared, skipped
end

-- Exact mirror: unbind every currently-bound key, apply saved keys, persist
-- once. Returns the number of key->command bindings applied.
local function applyBindings(bindings)
  for i = 1, GetNumBindings() do
    local command = GetBinding(i)
    if command and command ~= "" then
      local keys = { GetBindingKey(command) }
      for _, k in ipairs(keys) do
        SetBinding(k, nil)
      end
    end
  end
  local applied = 0
  for _, b in ipairs(bindings) do
    for _, key in ipairs(b.keys) do
      if SetBinding(key, b.command) then
        applied = applied + 1
      end
    end
  end
  SaveBindings(GetCurrentBindingSet())
  return applied
end

function Snapshot.Apply(profile, opts)
  opts = opts or {}
  if not profile then
    print(ERR .. "BucketBinds" .. R .. ": no profile to apply.")
    return
  end

  -- Combat guard: can't touch bindings/actions in lockdown. Defer the whole
  -- apply (auto-backup included) to PLAYER_REGEN_ENABLED.
  if InCombatLockdown() then
    if ns.QueueApply then ns.QueueApply(profile, opts) end
    say("in combat — restore deferred until you leave combat.")
    return "deferred"
  end

  if not opts.isUndo then
    BucketBindsDB.autobackup = Snapshot.Capture()
  end

  local mc, me, ms = applyMacros(profile.macros or {})
  local ap, ac, as = applyActions(profile.actions or {})
  local nb = applyBindings(profile.bindings or {})

  say("restore complete — %d bindings, %d action slots placed (%d cleared), %d macros (%d new, %d updated).",
    nb, ap, ac, mc + me, mc, me)
  if as > 0 or ms > 0 then
    say(WARN .. "skipped: %d action slots (unsupported type / unknown spell), %d macros (cap reached)." .. R,
      as, ms)
  end
  if profile.meta and profile.meta.bindingSet and profile.meta.bindingSet ~= GetCurrentBindingSet() then
    say(WARN .. "note: profile binding set (%s) differs from current (%s)." .. R,
      tostring(profile.meta.bindingSet), tostring(GetCurrentBindingSet()))
  end
  return "applied"
end
