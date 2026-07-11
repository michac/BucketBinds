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

-- Combat-defer queue: Snapshot.Apply enqueues here when InCombatLockdown();
-- drained on PLAYER_REGEN_ENABLED. Single pending apply (last one wins).
local pendingApply = nil
function ns.QueueApply(profile, opts)
  pendingApply = { profile = profile, opts = opts }
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function cmdHelp()
  print(COLOR .. "BucketBinds" .. R .. " commands:")
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
    if pendingApply then
      local p = pendingApply
      pendingApply = nil
      ns.Snapshot.Apply(p.profile, p.opts)
    end
  end
end)
