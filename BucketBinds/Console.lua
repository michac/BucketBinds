-- BucketBinds — in-game console (M4a). Loaded LAST so it can read ns.Commands /
-- ns.Dispatch / ns.SuggestCommand from Core. Pure, unprotected UI: a movable +
-- resizable terminal-styled window that runs the existing /bb surface with real
-- scrollback and schema-derived input affordances (live hint, autocomplete
-- dropdown, tab-complete, "did you mean?", ↑/↓ history).
local ADDON, ns = ...

ns.Console = ns.Console or {}
local Console = ns.Console
-- .echoChat: when the window is open, still mirror lines to chat unless this is
-- explicitly set false. nil (default) => echo. See Output.lua / ns.Emit.
Console.echoChat = Console.echoChat

local KEY = "|cffffd100"
local DIM = "|cff9aa0b0"
local R = "|r"

local FONT = "Interface\\AddOns\\BucketBinds\\Media\\JetBrainsMono.ttf"
local ROWH = 16
local MAXROWS = 8
local MIN_W, MIN_H = 360, 200
local DEF_W, DEF_H = 560, 340

-- Apply the bundled monospace font, falling back to a stock font object if the
-- .ttf can't be loaded (SetFont returns false on failure).
local function applyFont(obj, size, fallback)
  if not (obj and obj.SetFont) then return end
  if not obj:SetFont(FONT, size, "") then
    if obj.SetFontObject then obj:SetFontObject(fallback or ChatFontNormal) end
  end
end

local frame, output, editbox, hint, dropdown

-- ---------------------------------------------------------------------------
-- Geometry persistence (BucketBindsDB.console, init'd in Core)
-- ---------------------------------------------------------------------------

local function saveGeom()
  local db = BucketBindsDB.console
  if not (db and frame) then return end
  local point, _, relPoint, x, y = frame:GetPoint()
  db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
  db.w, db.h = frame:GetWidth(), frame:GetHeight()
end

local function restoreGeom()
  local db = BucketBindsDB.console or {}
  frame:SetSize(db.w or DEF_W, db.h or DEF_H)
  frame:ClearAllPoints()
  if db.point then
    frame:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
  else
    frame:SetPoint("CENTER")
  end
end

-- ---------------------------------------------------------------------------
-- Input parsing + affordances (all schema-derived)
-- ---------------------------------------------------------------------------

-- Split editbox text into (commandToken, hasTrailingArgs). `hasSpace` is true
-- once the user has typed past the command token (a space appears).
local function splitInput(text)
  local before = text:match("^(.*%s)%S*$")
  local hasSpace = before ~= nil
  local cmdToken
  if hasSpace then
    cmdToken = before:match("^%s*(%S+)")
  else
    cmdToken = text:match("^%s*(%S*)")
  end
  return (cmdToken or ""):lower(), hasSpace
end

local function hideDropdown()
  if dropdown then dropdown:Hide() end
end

local acquireRow  -- fwd

local function showDropdown(cmds)
  if not dropdown then return end
  local n = math.min(#cmds, MAXROWS)
  if n == 0 then dropdown:Hide(); return end
  for i = 1, n do
    local c = cmds[i]
    local r = acquireRow(i)
    r.cmd = c
    local label = KEY .. c.name .. R
    if c.args and c.args ~= "" then label = label .. "  " .. DIM .. c.args .. R end
    if c.desc and c.desc ~= "" then label = label .. "   " .. DIM .. c.desc .. R end
    r.text:SetText(label)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", dropdown, "TOPLEFT", 2, -2 - (i - 1) * ROWH)
    r:SetPoint("TOPRIGHT", dropdown, "TOPRIGHT", -2, -2 - (i - 1) * ROWH)
    r:SetHeight(ROWH)
    r:Show()
  end
  for i = n + 1, #dropdown.rows do dropdown.rows[i]:Hide() end
  dropdown:SetHeight(n * ROWH + 4)
  dropdown:Show()
end

local function updateAffordances()
  if not editbox then return end
  local text = editbox:GetText()
  local cmdToken, hasSpace = splitInput(text)

  if cmdToken == "" then
    hint:SetText("")
    hideDropdown()
    return
  end

  -- Live hint line: exact command → its args/desc; else "did you mean?".
  local c = ns.CommandByName and ns.CommandByName[cmdToken]
  if c then
    local s = KEY .. "/bb " .. c.name .. R
    if c.args and c.args ~= "" then s = s .. " " .. c.args end
    if c.desc and c.desc ~= "" then s = s .. "  — " .. DIM .. c.desc .. R end
    hint:SetText(s)
  else
    local guess = ns.SuggestCommand and ns.SuggestCommand(cmdToken)
    if guess then
      hint:SetText(DIM .. "did you mean " .. R .. KEY .. guess .. R .. DIM .. "?" .. R)
    else
      hint:SetText("")
    end
  end

  -- Autocomplete dropdown: only while still typing the command token.
  if hasSpace then
    hideDropdown()
  else
    local rows = {}
    for _, cc in ipairs(ns.Commands or {}) do
      if cc.name:sub(1, #cmdToken) == cmdToken then rows[#rows + 1] = cc end
    end
    showDropdown(rows)
  end
end

-- Tab-complete with cycling. State persists across consecutive Tab presses so
-- repeated Tab rotates through the candidate set.
local tab = {}

local function computeMatches(text)
  local before, tok = text:match("^(.*%s)(%S*)$")
  local matches, trailing = {}, ""
  if not before then
    -- completing the command token itself
    before = ""
    local low = text:lower()
    for _, c in ipairs(ns.Commands or {}) do
      if c.name:sub(1, #low) == low then matches[#matches + 1] = c.name end
    end
    if #matches == 1 then trailing = " " end
  else
    -- completing an argument via the command's context completer
    local cmd = before:match("^%s*(%S+)")
    local c = cmd and ns.CommandByName and ns.CommandByName[cmd:lower()]
    if c and c.complete then
      local low = tok:lower()
      for _, cand in ipairs(c.complete(tok) or {}) do
        cand = tostring(cand)
        if cand:lower():sub(1, #low) == low then matches[#matches + 1] = cand end
      end
    end
  end
  return before, matches, trailing
end

local function doTab(eb)
  local text = eb:GetText()
  if tab.output == text and tab.matches and #tab.matches > 0 then
    tab.idx = (tab.idx % #tab.matches) + 1  -- continue cycling
  else
    local before, matches, trailing = computeMatches(text)
    if #matches == 0 then return end
    tab.before, tab.matches, tab.trailing, tab.idx = before, matches, trailing, 1
  end
  local newText = tab.before .. tab.matches[tab.idx] .. (tab.trailing or "")
  eb:SetText(newText)
  eb:SetCursorPosition(#newText)
  tab.output = newText
  updateAffordances()
end

-- ---------------------------------------------------------------------------
-- Scrollback echo
-- ---------------------------------------------------------------------------

-- Colorize the echoed command in scrollback (per the spec: don't try to color
-- the live editbox; color the echo instead — free).
local function echoLine(text)
  local cmd, rest = text:match("^(%S+)%s*(.-)$")
  local shown = DIM .. "> " .. R .. KEY .. (cmd or text) .. R
  if rest and rest ~= "" then shown = shown .. " " .. rest end
  return shown
end

-- ---------------------------------------------------------------------------
-- Frame construction (lazy — built on first Toggle)
-- ---------------------------------------------------------------------------

function acquireRow(i)
  local r = dropdown.rows[i]
  if not r then
    r = CreateFrame("Button", nil, dropdown)
    r.text = r:CreateFontString(nil, "OVERLAY")
    applyFont(r.text, 12)
    r.text:SetPoint("LEFT", 4, 0)
    r.text:SetJustifyH("LEFT")
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(0.30, 0.50, 0.70, 0.30)
    r:SetScript("OnEnter", function(self)
      local c = self.cmd
      if not c then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("/bb " .. c.name, 1, 0.82, 0)
      if c.args and c.args ~= "" then GameTooltip:AddLine(c.args, 0.6, 0.8, 1) end
      if c.desc and c.desc ~= "" then GameTooltip:AddLine(c.desc, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
      if not self.cmd then return end
      local t = self.cmd.name .. " "
      editbox:SetText(t)
      editbox:SetCursorPosition(#t)
      editbox:SetFocus()
      updateAffordances()
    end)
    dropdown.rows[i] = r
  end
  return r
end

local function ensureFrame()
  if frame then return end

  frame = CreateFrame("Frame", "BucketBindsConsole", UIParent, "BackdropTemplate")
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  frame:SetBackdropColor(0.04, 0.05, 0.07, 0.94)
  frame:SetBackdropBorderColor(0.28, 0.46, 0.66, 0.85)

  -- Movable
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); saveGeom() end)

  -- Resizable
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_W, MIN_H)
  end

  -- Title bar
  local titlebar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  titlebar:SetPoint("TOPLEFT", 1, -1)
  titlebar:SetPoint("TOPRIGHT", -1, -1)
  titlebar:SetHeight(20)
  titlebar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
  titlebar:SetBackdropColor(0.10, 0.14, 0.20, 0.95)
  local title = titlebar:CreateFontString(nil, "OVERLAY")
  applyFont(title, 12, GameFontNormal)
  title:SetPoint("LEFT", 8, 0)
  title:SetText(KEY .. "BucketBinds" .. R .. DIM .. " console" .. R)

  local close = CreateFrame("Button", nil, titlebar, "UIPanelCloseButton")
  close:SetSize(22, 22)
  close:SetPoint("RIGHT", 2, 0)
  close:SetScript("OnClick", function() frame:Hide() end)

  -- Output scrollback
  output = CreateFrame("ScrollingMessageFrame", nil, frame)
  output:SetPoint("TOPLEFT", 8, -26)
  output:SetPoint("BOTTOMRIGHT", -10, 52)
  applyFont(output, 13)
  output:SetJustifyH("LEFT")
  output:SetFading(false)
  output:SetMaxLines(500)
  output:SetHyperlinksEnabled(true)
  output:EnableMouseWheel(true)
  output:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then
      if IsShiftKeyDown() then self:ScrollToTop() else self:ScrollUp() end
    else
      if IsShiftKeyDown() then self:ScrollToBottom() else self:ScrollDown() end
    end
  end)

  -- Live hint line (between output and input)
  hint = frame:CreateFontString(nil, "OVERLAY")
  applyFont(hint, 11)
  hint:SetPoint("BOTTOMLEFT", 10, 32)
  hint:SetPoint("BOTTOMRIGHT", -10, 32)
  hint:SetJustifyH("LEFT")
  hint:SetHeight(14)
  hint:SetText("")

  -- Input editbox
  editbox = CreateFrame("EditBox", nil, frame, "BackdropTemplate")
  editbox:SetPoint("BOTTOMLEFT", 8, 8)
  editbox:SetPoint("BOTTOMRIGHT", -10, 8)
  editbox:SetHeight(22)
  editbox:SetAutoFocus(false)
  editbox:SetHistoryLines(64)
  editbox:SetTextInsets(6, 6, 0, 0)
  applyFont(editbox, 13)
  editbox:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  editbox:SetBackdropColor(0.02, 0.02, 0.03, 0.9)
  editbox:SetBackdropBorderColor(0.22, 0.36, 0.52, 0.8)
  editbox:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    hideDropdown()
    self:ClearFocus()
  end)
  editbox:SetScript("OnEditFocusLost", function() hideDropdown() end)
  editbox:SetScript("OnTabPressed", function(self) doTab(self) end)
  editbox:SetScript("OnTextChanged", function() updateAffordances() end)
  editbox:SetScript("OnEnterPressed", function(self)
    local text = self:GetText():match("^%s*(.-)%s*$")
    if text == "" then return end
    self:AddHistoryLine(text)
    output:AddMessage(echoLine(text))
    self:SetText("")
    hideDropdown()
    ns.Dispatch(text)
  end)

  -- Autocomplete dropdown (floats above the input, grows upward)
  dropdown = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  dropdown:SetPoint("BOTTOMLEFT", editbox, "TOPLEFT", 0, 18)
  dropdown:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
  dropdown:SetFrameLevel(frame:GetFrameLevel() + 20)
  dropdown:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  dropdown:SetBackdropColor(0.06, 0.08, 0.11, 0.97)
  dropdown:SetBackdropBorderColor(0.28, 0.46, 0.66, 0.85)
  dropdown.rows = {}
  dropdown:Hide()

  -- Resize grip
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing(); saveGeom() end)

  restoreGeom()

  output:AddMessage(DIM .. "BucketBinds console — type a command, " .. R .. KEY .. "help" .. R ..
    DIM .. " to list them. Tab completes, ↑/↓ recall history." .. R)
end

-- ---------------------------------------------------------------------------
-- Public API (consumed by ns.Emit / the slash handler)
-- ---------------------------------------------------------------------------

-- Append one already-formatted line; returns true iff the window is open (so
-- ns.Emit knows whether it still needs to echo to chat).
function Console.Append(msg)
  if not (frame and frame:IsShown() and output) then return false end
  output:AddMessage(msg)
  return true
end

function Console.Toggle()
  ensureFrame()
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
    editbox:SetFocus()
  end
end

function Console.Show()
  ensureFrame()
  frame:Show()
  editbox:SetFocus()
end

function Console.Hide()
  if frame then frame:Hide() end
end
