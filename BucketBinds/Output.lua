-- BucketBinds — output sink. Loaded FIRST so every module can route its
-- already-formatted lines through one door.
--
-- ns.Emit(msg): send one finished line to the console if it's open, and (by
-- default) also echo it to chat so nothing is lost. The console owns the
-- decision to suppress the chat echo via ns.Console.echoChat.
local ADDON, ns = ...

function ns.Emit(msg)
  local shown = ns.Console and ns.Console.Append and ns.Console.Append(msg)
  if not shown or ns.Console.echoChat ~= false then
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  end
end
