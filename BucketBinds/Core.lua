-- BucketBinds — core: namespace, saved vars, slash commands.
-- M1 (snapshot/restore) and M2 (dump) hang off this; right now it just loads
-- the seed and reports it so we can confirm the addon wiring in-game.
local ADDON, ns = ...

BucketBindsDB = BucketBindsDB or { profiles = {} }

local function report()
  local seed = ns.SEED
  if not seed then
    print("|cffff4040BucketBinds|r: seed data failed to load.")
    return
  end
  local nSpecs, nBuckets = 0, #seed.buckets
  for _ in pairs(seed.specs) do nSpecs = nSpecs + 1 end
  print(("|cff40c0ffBucketBinds|r loaded: %d buckets, %d specs."):format(nBuckets, nSpecs))
  local _, class = UnitClass("player")
  print(("Your class: %s. Use |cffffd100/bb|r for commands. (M1/M2 not built yet.)"):format(class or "?"))
end

SLASH_BUCKETBINDS1 = "/bb"
SLASH_BUCKETBINDS2 = "/bucketbinds"
SlashCmdList.BUCKETBINDS = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", "")
  if msg == "" or msg == "help" then
    print("|cff40c0ffBucketBinds|r commands:")
    print("  |cffffd100/bb status|r — show loaded seed + your spec")
    print("  (snapshot/restore/dump land in M1–M2)")
  elseif msg == "status" then
    report()
  else
    print("|cffff4040BucketBinds|r: unknown command '"..msg.."'. Try /bb help.")
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", report)
