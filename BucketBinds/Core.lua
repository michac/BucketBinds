-- BucketBinds — core: namespace, saved vars, slash commands, combat queue.
-- M1 (snapshot/restore) hangs off ns.Snapshot (Snapshot.lua, loaded first).
local ADDON, ns = ...

BucketBindsDB = BucketBindsDB or {}
BucketBindsDB.profiles = BucketBindsDB.profiles or {}

local COLOR = "|cff40c0ff"
local KEY = "|cffffd100"
local ERR = "|cffff4040"
local R = "|r"

local function report()
  local seed = ns.SEED
  if not seed then
    print(ERR .. "BucketBinds" .. R .. ": seed data failed to load.")
    return
  end
  local nSpecs, nBuckets = 0, #seed.buckets
  for _ in pairs(seed.specs) do nSpecs = nSpecs + 1 end
  print((COLOR .. "BucketBinds" .. R .. " loaded: %d buckets, %d specs."):format(nBuckets, nSpecs))
  local _, class = UnitClass("player")
  local nProfiles = 0
  for _ in pairs(BucketBindsDB.profiles) do nProfiles = nProfiles + 1 end
  print(("Class: %s. %d saved profile(s). Use " .. KEY .. "/bb help" .. R .. " for commands."):format(class or "?", nProfiles))
end

-- Combat-defer queue: Snapshot.Apply / Dump.Run enqueue a thunk when
-- InCombatLockdown(); drained on PLAYER_REGEN_ENABLED. Single pending action
-- (last one wins) — both restore and dump defer through the same drain.
local pendingAction = nil
function ns.QueueAction(thunk)
  pendingAction = thunk
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function cmdHelp()
  print(COLOR .. "BucketBinds" .. R .. " commands:")
  print("  " .. KEY .. "/bb dump" .. R .. " — place + bind your spec's abilities across the bars (auto-backs-up first)")
  print("  " .. KEY .. "/bb dump <Spec>" .. R .. " or " .. KEY .. "/bb dump <Class> <Spec>" .. R .. " — dump a specific spec")
  print("  " .. KEY .. "/bb dump … --nobind" .. R .. " — place abilities but leave your keybinds untouched")
  print("  " .. KEY .. "/bb spill" .. R .. " — drop every learned-but-unplaced ability onto the reserve bars (" .. KEY .. "spill clear" .. R .. " to undo)")
  print("  " .. KEY .. "/bb ring" .. R .. " — send that same overflow set to an OPie ring instead (needs OPie; " .. KEY .. "ring clear" .. R .. " to remove)")
  print("  " .. KEY .. "/bb test" .. R .. " — smoke-test the place+bind path (Recuperate → ALT-0; " .. KEY .. "test clear" .. R .. " to undo)")
  print("  " .. KEY .. "/bb diagnostics" .. R .. " — read-only resolution/placement report for the active spec (accumulates per char/spec; " .. KEY .. "diagnostics clear" .. R .. " wipes the store)")
  print("  " .. KEY .. "/bb save <name>" .. R .. " — capture bindings + bars + macros to a profile")
  print("  " .. KEY .. "/bb restore <name>" .. R .. " — mirror a profile back (auto-backs-up first)")
  print("  " .. KEY .. "/bb undo" .. R .. " — restore the pre-restore auto-backup")
  print("  " .. KEY .. "/bb list" .. R .. " — list saved profiles")
  print("  " .. KEY .. "/bb delete <name>" .. R .. " — delete a profile")
  print("  " .. KEY .. "/bb status" .. R .. " — show loaded seed + your class")
end

local function counts(p)
  return #(p.bindings or {}), #(p.actions or {}), #(p.macros or {})
end

local function cmdSave(name)
  if name == "" then print(ERR .. "usage:" .. R .. " /bb save <name>"); return end
  local existed = BucketBindsDB.profiles[name] ~= nil
  local p = ns.Snapshot.Capture()
  BucketBindsDB.profiles[name] = p
  local nb, na, nm = counts(p)
  print((COLOR .. "BucketBinds" .. R .. ": saved '%s' — %d bindings, %d action slots, %d macros%s"):format(
    name, nb, na, nm, existed and " " .. KEY .. "(overwrote)" .. R or ""))
end

local function cmdRestore(name)
  if name == "" then print(ERR .. "usage:" .. R .. " /bb restore <name>"); return end
  local p = BucketBindsDB.profiles[name]
  if not p then print(ERR .. "BucketBinds" .. R .. ": no profile '" .. name .. "'. Try /bb list."); return end
  ns.Snapshot.Apply(p)
end

local function cmdUndo()
  if not BucketBindsDB.autobackup then
    print(ERR .. "BucketBinds" .. R .. ": nothing to undo (no auto-backup yet).")
    return
  end
  print(COLOR .. "BucketBinds" .. R .. ": restoring pre-restore auto-backup…")
  ns.Snapshot.Apply(BucketBindsDB.autobackup, { isUndo = true })
end

local function cmdDump(rest)
  if not ns.Dump then print(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return end
  -- Strip a --nobind flag anywhere in the args before spec resolution.
  local opts = {}
  rest = rest:gsub("%-%-nobind", function() opts.noBind = true; return "" end)
  rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
  local key = ns.Dump.Resolve(rest)
  if not key then
    local _, ct = UnitClass("player")
    if rest == "" then
      print(ERR .. "BucketBinds" .. R .. ": couldn't detect your spec. Pick one:")
      for _, k in ipairs(ns.Dump.AvailableKeys(ct)) do print("  " .. KEY .. k .. R) end
    else
      print(ERR .. "BucketBinds" .. R .. ": no spec matching '" .. rest .. "'. Available:")
      for _, k in ipairs(ns.Dump.AvailableKeys()) do print("  " .. KEY .. k .. R) end
    end
    return
  end
  ns.Dump.Run(key, opts)
end

local function cmdSpill(rest)
  if not ns.Dump or not ns.Dump.Spill then
    print(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Spill(opts)
end

local function cmdRing(rest)
  if not ns.Dump or not ns.Dump.Ring then
    print(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Ring(opts)
end

local function cmdTest(rest)
  if not ns.Dump or not ns.Dump.Test then
    print(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Test(opts)
end

local function cmdDiagnostics(rest)
  if not ns.Dump or not ns.Dump.Diagnostics then
    print(ERR .. "BucketBinds" .. R .. ": dump module failed to load."); return
  end
  local opts = {}
  if (rest or ""):lower():match("clear") then opts.clear = true end
  ns.Dump.Diagnostics(opts)
end

local function cmdList()
  local any = false
  for name, p in pairs(BucketBindsDB.profiles) do
    any = true
    local m = p.meta or {}
    local nb, na, nm = counts(p)
    local when = m.created and date("%Y-%m-%d", m.created) or "?"
    print(("  " .. KEY .. "%s" .. R .. " — %s (%s), spec %s, %s · %d binds / %d acts / %d macros"):format(
      name, m.char or "?", m.class or "?", tostring(m.specID or "?"), when, nb, na, nm))
  end
  if not any then print(COLOR .. "BucketBinds" .. R .. ": no saved profiles. " .. KEY .. "/bb save <name>" .. R) end
end

local function cmdDelete(name)
  if name == "" then print(ERR .. "usage:" .. R .. " /bb delete <name>"); return end
  if BucketBindsDB.profiles[name] then
    BucketBindsDB.profiles[name] = nil
    print(COLOR .. "BucketBinds" .. R .. ": deleted '" .. name .. "'.")
  else
    print(ERR .. "BucketBinds" .. R .. ": no profile '" .. name .. "'.")
  end
end

SLASH_BUCKETBINDS1 = "/bb"
SLASH_BUCKETBINDS2 = "/bucketbinds"
SlashCmdList.BUCKETBINDS = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "" or cmd == "help" then
    cmdHelp()
  elseif cmd == "status" then
    report()
  elseif cmd == "dump" then
    cmdDump(rest)
  elseif cmd == "spill" then
    cmdSpill(rest)
  elseif cmd == "ring" then
    cmdRing(rest)
  elseif cmd == "test" then
    cmdTest(rest)
  elseif cmd == "diagnostics" or cmd == "diag" then
    cmdDiagnostics(rest)
  elseif cmd == "save" then
    cmdSave(rest)
  elseif cmd == "restore" then
    cmdRestore(rest)
  elseif cmd == "undo" then
    cmdUndo()
  elseif cmd == "list" then
    cmdList()
  elseif cmd == "delete" then
    cmdDelete(rest)
  else
    print(ERR .. "BucketBinds" .. R .. ": unknown command '" .. cmd .. "'. Try /bb help.")
  end
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
