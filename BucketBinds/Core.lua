-- BucketBinds — core: namespace, saved vars, slash commands, combat queue.
-- M1 (snapshot/restore) hangs off ns.Snapshot (Snapshot.lua, loaded first).
-- M4a: commands are defined once in ns.Commands; ns.Dispatch routes both the
-- slash handler and the console EditBox off that single schema.
local ADDON, ns = ...

BucketBindsDB = BucketBindsDB or {}
BucketBindsDB.profiles = BucketBindsDB.profiles or {}
BucketBindsDB.console = BucketBindsDB.console or {}

local COLOR = "|cff40c0ff"
local KEY = "|cffffd100"
local ERR = "|cffff4040"
local R = "|r"

-- Every finished line routes through the shared sink (Output.lua) so the
-- console captures it when open. Wrapped (not a direct alias) to stay robust
-- against load order; ns.Emit only fires from post-login handlers anyway.
local function emit(msg) return ns.Emit(msg) end

local function report()
  local seed = ns.SEED
  if not seed then
    emit(ERR .. "BucketBinds" .. R .. ": seed data failed to load.")
    return
  end
  local nSpecs, nBuckets = 0, #seed.buckets
  for _ in pairs(seed.specs) do nSpecs = nSpecs + 1 end
  emit((COLOR .. "BucketBinds" .. R .. " loaded: %d buckets, %d specs."):format(nBuckets, nSpecs))
  local _, class = UnitClass("player")
  local nProfiles = 0
  for _ in pairs(BucketBindsDB.profiles) do nProfiles = nProfiles + 1 end
  emit(("Class: %s. %d saved profile(s). Use " .. KEY .. "/bb help" .. R .. " for commands."):format(class or "?", nProfiles))
end

-- Combat-defer queue: Snapshot.Apply / Dump.Run enqueue a thunk when
-- InCombatLockdown(); drained on PLAYER_REGEN_ENABLED. Single pending action
-- (last one wins) — both restore and dump defer through the same drain.
local pendingAction = nil
function ns.QueueAction(thunk)
  pendingAction = thunk
end

-- ---------------------------------------------------------------------------
-- Command handlers (reused as-is by the ns.Commands schema below)
-- ---------------------------------------------------------------------------

local function counts(p)
  return #(p.bindings or {}), #(p.actions or {}), #(p.macros or {})
end

local function cmdSave(name)
  if name == "" then emit(ERR .. "usage:" .. R .. " /bb save <name>"); return end
  local existed = BucketBindsDB.profiles[name] ~= nil
  local p = ns.Snapshot.Capture()
  BucketBindsDB.profiles[name] = p
  local nb, na, nm = counts(p)
  emit((COLOR .. "BucketBinds" .. R .. ": saved '%s' — %d bindings, %d action slots, %d macros%s"):format(
    name, nb, na, nm, existed and " " .. KEY .. "(overwrote)" .. R or ""))
end

local function cmdRestore(name)
  if name == "" then emit(ERR .. "usage:" .. R .. " /bb restore <name>"); return end
  local p = BucketBindsDB.profiles[name]
  if not p then emit(ERR .. "BucketBinds" .. R .. ": no profile '" .. name .. "'. Try /bb list."); return end
  ns.Snapshot.Apply(p)
end

local function cmdUndo()
  if not BucketBindsDB.autobackup then
    emit(ERR .. "BucketBinds" .. R .. ": nothing to undo (no auto-backup yet).")
    return
  end
  emit(COLOR .. "BucketBinds" .. R .. ": restoring pre-restore auto-backup…")
  ns.Snapshot.Apply(BucketBindsDB.autobackup, { isUndo = true })
end

local function cmdDump(rest)
  if not ns.Dump then emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return end
  -- Strip a --nobind flag anywhere in the args before spec resolution.
  local opts = {}
  rest = rest:gsub("%-%-nobind", function() opts.noBind = true; return "" end)
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
  local key = ns.Dump.Resolve(rest)
  if not key then
    local _, ct = UnitClass("player")
    if rest == "" then
      emit(ERR .. "BucketBinds" .. R .. ": couldn't detect your spec. Pick one:")
      for _, k in ipairs(ns.Dump.AvailableKeys(ct)) do emit("  " .. KEY .. k .. R) end
    else
      emit(ERR .. "BucketBinds" .. R .. ": no spec matching '" .. rest .. "'. Available:")
      for _, k in ipairs(ns.Dump.AvailableKeys()) do emit("  " .. KEY .. k .. R) end
    end
    return
  end
  ns.Dump.Run(key, opts)
end

local function cmdSpill(rest)
  if not ns.Dump or not ns.Dump.Spill then
    emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Spill(opts)
end

local function cmdRing(rest)
  if not ns.Dump or not ns.Dump.Ring then
    emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Ring(opts)
end

local function cmdTest(rest)
  if not ns.Dump or not ns.Dump.Test then
    emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Test(opts)
end

local function cmdDiagnostics(rest)
  if not ns.Dump or not ns.Dump.Diagnostics then
    emit(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Diagnostics(opts)
end

local function cmdMacros(rest)
  if not ns.Macros then
    emit(ERR .. "BucketBinds" .. R .. ": macro module failed to load."); return
  end
  if (rest or ""):lower():match("clear") then
    ns.Macros.Clear({})
  else
    ns.Macros.RunStandalone({ spec = rest })
  end
end

local function cmdList()
  local any = false
  for name, p in pairs(BucketBindsDB.profiles) do
    any = true
    local m = p.meta or {}
    local nb, na, nm = counts(p)
    local when = m.created and date("%Y-%m-%d", m.created) or "?"
    emit(("  " .. KEY .. "%s" .. R .. " — %s (%s), spec %s, %s · %d binds / %d acts / %d macros"):format(
      name, m.char or "?", m.class or "?", tostring(m.specID or "?"), when, nb, na, nm))
  end
  if not any then emit(COLOR .. "BucketBinds" .. R .. ": no saved profiles. " .. KEY .. "/bb save <name>" .. R) end
end

local function cmdDelete(name)
  if name == "" then emit(ERR .. "usage:" .. R .. " /bb delete <name>"); return end
  if BucketBindsDB.profiles[name] then
    BucketBindsDB.profiles[name] = nil
    emit(COLOR .. "BucketBinds" .. R .. ": deleted '" .. name .. "'.")
  else
    emit(ERR .. "BucketBinds" .. R .. ": no profile '" .. name .. "'.")
  end
end

-- ---------------------------------------------------------------------------
-- Completion helpers (schema `complete` callbacks)
-- ---------------------------------------------------------------------------

local function clearOnly() return { "clear" } end

local function profileNames()
  local t = {}
  for name in pairs(BucketBindsDB.profiles) do t[#t + 1] = name end
  table.sort(t)
  return t
end

-- shallow copy of `list` with the extra scalars appended
local function append(list, ...)
  local out = {}
  for _, v in ipairs(list or {}) do out[#out + 1] = v end
  for i = 1, select("#", ...) do out[#out + 1] = select(i, ...) end
  return out
end

local function specKeys()
  return (ns.Dump and ns.Dump.AvailableKeys and ns.Dump.AvailableKeys()) or {}
end

-- cmdHelp is a real function (defined below) but referenced by the schema; it
-- reads ns.Commands at call time, so the forward reference resolves fine.
local cmdHelp

-- ---------------------------------------------------------------------------
-- The command schema — the single source of truth. Add a row here and help +
-- every console affordance (hint line, autocomplete, tab-complete, tooltips)
-- light up for free.
-- ---------------------------------------------------------------------------

ns.Commands = {
  { name = "dump", args = "[<Class>] <Spec> [--nobind]",
    desc = "Place + bind your spec's abilities across the bars (auto-backs-up)",
    handler = cmdDump, complete = specKeys },
  { name = "spill", args = "[clear]",
    desc = "Drop every learned-but-unplaced ability onto the reserve bars",
    handler = cmdSpill, complete = clearOnly },
  { name = "ring", args = "[clear]",
    desc = "Send that overflow set to an OPie ring instead (needs OPie)",
    handler = cmdRing, complete = clearOnly },
  { name = "test", args = "[clear]",
    desc = "Smoke-test the place+bind path (Recuperate → ALT-0)",
    handler = cmdTest, complete = clearOnly },
  { name = "diagnostics", args = "[clear]", aliases = { "diag" },
    desc = "Read-only resolution/placement report for the active spec",
    handler = cmdDiagnostics, complete = clearOnly },
  { name = "macros", args = "[<Spec>|clear]",
    desc = "Utility macros: set-focus, smart interrupt, items, prep band",
    handler = cmdMacros, complete = function() return append(specKeys(), "clear") end },
  { name = "save", args = "<name>",
    desc = "Capture bindings + bars + macros to a profile",
    handler = cmdSave },
  { name = "restore", args = "<name>",
    desc = "Mirror a profile back (auto-backs-up first)",
    handler = cmdRestore, complete = profileNames },
  { name = "delete", args = "<name>",
    desc = "Delete a profile",
    handler = cmdDelete, complete = profileNames },
  { name = "undo",
    desc = "Restore the pre-restore auto-backup",
    handler = cmdUndo },
  { name = "list",
    desc = "List saved profiles",
    handler = cmdList },
  { name = "status", args = "",
    desc = "Show loaded seed + your class",
    handler = report },
  { name = "help",
    desc = "Show this help",
    handler = function() cmdHelp() end },
}

-- name/alias → command row (built once at load)
local byName = {}
for _, c in ipairs(ns.Commands) do
  byName[c.name] = c
  if c.aliases then
    for _, a in ipairs(c.aliases) do byName[a] = c end
  end
end
ns.CommandByName = byName

-- ---------------------------------------------------------------------------
-- Schema-derived help + "did you mean?" + the shared router
-- ---------------------------------------------------------------------------

function cmdHelp()
  emit(COLOR .. "BucketBinds" .. R .. " commands:")
  for _, c in ipairs(ns.Commands) do
    local line = "  " .. KEY .. "/bb " .. c.name .. R
    if c.args and c.args ~= "" then line = line .. " " .. c.args end
    if c.desc and c.desc ~= "" then line = line .. " — " .. c.desc end
    emit(line)
  end
end

-- classic DP edit distance (small strings — command names)
local function levenshtein(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev, cur = {}, {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    cur[0] = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local del, ins, sub = prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost
      local m = del < ins and del or ins
      if sub < m then m = sub end
      cur[j] = m
    end
    for j = 0, lb do prev[j] = cur[j] end
  end
  return prev[lb]
end

-- Nearest command name for an unknown token: prefix match first, then fuzzy
-- (Levenshtein ≤ 2). Returns nil if nothing is close.
function ns.SuggestCommand(cmd)
  for _, c in ipairs(ns.Commands) do
    if #cmd > 0 and c.name:sub(1, #cmd) == cmd then return c.name end
  end
  local best, bestd = nil, 3
  for _, c in ipairs(ns.Commands) do
    local d = levenshtein(cmd, c.name)
    if d < bestd then best, bestd = c.name, d end
    for _, a in ipairs(c.aliases or {}) do
      local da = levenshtein(cmd, a)
      if da < bestd then best, bestd = c.name, da end
    end
  end
  return best
end

-- The one router shared by the slash handler and the console EditBox. The
-- console toggle is deliberately NOT here (an empty console line must not close
-- the window) — callers handle the empty/"console" case before dispatching.
function ns.Dispatch(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "" then cmdHelp(); return end
  local c = byName[cmd]
  if c then
    c.handler(rest)
    return
  end
  local guess = ns.SuggestCommand(cmd)
  if guess then
    emit(ERR .. "BucketBinds" .. R .. ": unknown command '" .. cmd .. "'. Did you mean " ..
      KEY .. "/bb " .. guess .. R .. "?")
  else
    emit(ERR .. "BucketBinds" .. R .. ": unknown command '" .. cmd .. "'. Try " .. KEY .. "/bb help" .. R .. ".")
  end
end

SLASH_BUCKETBINDS1 = "/bb"
SLASH_BUCKETBINDS2 = "/bucketbinds"
SlashCmdList.BUCKETBINDS = function(msg)
  local trimmed = (msg or ""):match("^%s*(.-)%s*$")
  if trimmed == "" or trimmed:lower() == "console" then
    if ns.Console and ns.Console.Toggle then
      ns.Console.Toggle()
    else
      cmdHelp()  -- console module unavailable — fall back to text help
    end
    return
  end
  ns.Dispatch(msg)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    report()
  elseif event == "PLAYER_REGEN_ENABLED" then
    if pendingAction then
      local thunk = pendingAction
      pendingAction = nil
      thunk()
    end
  end
end)
