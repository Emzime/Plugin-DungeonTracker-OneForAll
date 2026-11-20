local ADDON, NS = ...

-- OneForAll Dungeon Tracker: a plugin for OneForAll (a separate addon). It reaches OneForAll only through its public API
-- (OneForAllAPI, OneForAll's API.lua), so either can be updated without touching the other.
--
-- A small window that opens when you enter a dungeon or raid, with the bosses you killed (and when) and the time spent
-- inside. The clock stops once every required boss is down (rare and summoned bosses are optional).
-- Inspired by Dungeon Journal's tracker (its options and the reset button); own code, on OneForAll's data.
-- Kills are found without the combat log (registering COMBAT_LOG_EVENT_UNFILTERED is forbidden in the Forever client):
-- ENCOUNTER_END / BOSS_KILL when the client sends them, a dead boss seen as a unit (target, focus, mouseover, boss
-- frames, nameplates, the group's targets) and a looted corpse (GetLootSourceInfo).
-- The window shows Time | XP earned | Gold (gold in place of XP at the level cap), then the bosses. Its options are the
-- ones of Dungeon Journal's tracker (OneForAll > Plugins > Dungeon Tracker), kept in OneForAll's profile under
-- "plugin.OneForAll_DungeonTracker.<key>" (API.NewOptions):
--   never (never opens by itself; /ofa run still opens it), solo (opens by itself without a group too; on),
--   hideTime / hideXP / hideGold / hideBosses (hide a part); "Hide Tracker" is the run's own `hidden` (ticked by the
--   X, a new run unticks it). Also pos { point, x, y }, folded.
-- XP: the XP gained while inside, less quest turn-ins. Gold: the money gained while inside (gains only: buying or
-- repairing doesn't take it back). Both are counted like Dungeon Journal does.
-- Run state per character (survives reloads and short trips outside, e.g. a corpse run):
-- OneForAllDungeonTrackerCharDB.run
--   { id = instance ID, key = dungeon name (OneForAll's English name) or nil, name = instance name from the game,
--     active = seconds inside before `since`, since = time() the current stay inside started (nil outside),
--     left = time() of leaving, kills = { [boss key] = seconds into the run }, extra = { boss keys not in OneForAll's
--     data, in kill order }, done = seconds (clock stopped), hidden = closed by the player for this run,
--     manual = opened by /ofa run, xp = mobs' XP, money = copper earned }

local API = OneForAllAPI
if not (API and type(API.VERSION) == "number" and API.VERSION >= 2) then
  -- OneForAll without the plugin API (older than the version with API.lua): nothing to do
  print("|cffd8b46aOneForAll Dungeon Tracker:|r this OneForAll has no plugin API (OneForAllAPI). Update OneForAll.")
  return
end
local W = API.Widgets
local L = NS.L

local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
  or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
API.RegisterPlugin(ADDON, { title = "Dungeon Tracker", version = VERSION })
-- the options, in OneForAll's profile under "plugin.OneForAll_DungeonTracker.<key>"
local opts = API.NewOptions(ADDON, { never = false, solo = true, hideTime = false, hideXP = false, hideGold = false,
  hideBosses = false, folded = false })
local R = {}
NS.Tracker = R

local RESUME = 30 * 60 -- back inside the same instance within 30 minutes: the run goes on (corpse run, repairs)
local WIDTH, ROW_H = 236, 16
local floor, fmt = math.floor, string.format

local function qol(key) return opts:Get(key) end
local function setQol(key, v) opts:Set(key, v) end
local function opt(key) return qol(key) and true or false end
local function inGroup()
  if not IsInGroup then return false end
  local ok, g = pcall(IsInGroup)
  return ok and g and true or false
end
local function now() return time and time() or 0 end
local function secret(...) return API.IsSecret(...) end
local function say(text) API.Print(text) end
local function safe(tag, fn, ...) return API.SafeCall(tag, fn, ...) end
local function dungeonName(name) return API.DungeonName(name) end
local function bossName(name) return API.Name(name) end

local function clock(s)
  s = floor(math.max(0, s or 0))
  if s >= 3600 then return fmt("%d:%02d:%02d", floor(s / 3600), floor(s % 3600 / 60), s % 60) end
  return fmt("%d:%02d", floor(s / 60), s % 60)
end
R.Clock = clock -- (tests)

-- this character's saved data (loaded with the addon, before PLAYER_LOGIN)
local function charDB()
  if type(OneForAllDungeonTrackerCharDB) ~= "table" then OneForAllDungeonTrackerCharDB = {} end
  local db = OneForAllDungeonTrackerCharDB
  -- the run of a OneForAll build with the tracker built in (6.2.x-dt), copied once (read through the API: OneForAll's
  -- own saved data stays as it is)
  if not db.migrated then
    db.migrated = true
    local old = API.GetCharacterData()
    if db.run == nil and old and type(old.dungeonRun) == "table" then db.run = API.Copy(old.dungeonRun) end
  end
  return db
end
local function run()
  local r = charDB().run
  return type(r) == "table" and r or nil
end
local function elapsed(r)
  if not r then return 0 end
  if r.done then return r.done end
  return (r.active or 0) + (r.since and math.max(0, now() - r.since) or 0)
end

-- XP and gold ---------------------------------------------------------------------------------------------------------
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
-- gold and silver once there is a gold; below that, silver and copper
local function goldText(copper)
  copper = floor(tonumber(copper) or 0)
  local g, sv, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
  if g > 0 then return g .. GOLD_ICON .. " " .. sv .. SILVER_ICON end
  if sv > 0 then return sv .. SILVER_ICON .. " " .. c .. COPPER_ICON end
  return c .. COPPER_ICON
end
R.GoldText = goldText -- (tests)
local function thousands(n)
  n = floor(tonumber(n) or 0)
  if BreakUpLargeNumbers then local ok, t = pcall(BreakUpLargeNumbers, n); if ok and type(t) == "string" then return t end end
  return tostring(n)
end
-- at the level cap (or with XP turned off) no XP comes: the tracker shows the gold instead
local function capped()
  if IsXPUserDisabled then
    local ok, off = pcall(IsXPUserDisabled)
    if ok and off == true then return true end
  end
  local level = UnitLevel and UnitLevel("player")
  local max = 60
  if GetMaxPlayerLevel then
    local ok, m = pcall(GetMaxPlayerLevel)
    if ok and type(m) == "number" and m > 0 then max = m end
  end
  return type(level) == "number" and not secret(level) and level >= max
end

-- Dungeons -----------------------------------------------------------------------------------------------------------
-- the dungeons of an instance ID (more than one where wings share an instance: Scarlet Monastery, Dire Maul,
-- Blackrock Spire)
local function byInstance(id) return id and API.GetDungeonsByInstanceID(id) or {} end
local function dungeonByKey(key) return key and API.GetDungeon(key) or nil end
local function npcOf(guid)
  if type(guid) ~= "string" or secret(guid) then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
  return tonumber(id)
end
-- Learned per account: OneForAll's boss names are English, the client's encounter names are not. Each encounter ID
-- (the same in every language) is tied to the NPC ID of the boss seen during that fight, and each boss NPC ID to the
-- name the client gives it, so the next kills match whatever the language.
local function acctDB()
  OneForAllDungeonTrackerDB = type(OneForAllDungeonTrackerDB) == "table" and OneForAllDungeonTrackerDB or {}
  local db = OneForAllDungeonTrackerDB
  db.names = type(db.names) == "table" and db.names or {}
  db.encounters = type(db.encounters) == "table" and db.encounters or {}
  db.log = type(db.log) == "table" and db.log or {}
  return db
end
local function learnedName(id) return id and acctDB().names[id] or nil end
local function learnName(id, name)
  if not id or type(name) ~= "string" or name == "" or secret(name) then return end
  acctDB().names[id] = name
end

-- the diagnostic log: always kept (last LOG_MAX lines, in the account's SavedVariables file); echoed in the chat
-- after /ofa run debug
local LOG_MAX = 300
local function dlog(fmtStr, ...)
  local db = acctDB()
  local args = { ... }
  for i = 1, select("#", ...) do
    local v = args[i]
    if secret(v) then args[i] = "<secret>" else args[i] = tostring(v) end
  end
  local ok, line = pcall(fmt, fmtStr, unpack(args, 1, select("#", ...)))
  line = (date and date("%H:%M:%S") or "") .. " " .. (ok and line or fmtStr)
  table.insert(db.log, line)
  while #db.log > LOG_MAX do table.remove(db.log, 1) end
  if db.debug then say("|cff9999ffDT|r " .. line) end
end
R.Log = dlog -- (tests)

local function optional(b)
  return (b.rare or API.IsSummonedBoss(b.npcID)) and true or false
end
local function norm(s)
  s = string.lower(tostring(s or ""))
  return (s:gsub("^the ", ""):gsub("[%s%p]", ""))
end
-- the boss of `d` a name stands for (an encounter name in the client's language, or a unit's name)
local function bossByName(d, name)
  local want = norm(name)
  if not d or want == "" then return nil end
  for _, b in API.ipairs(d.bosses or {}) do
    if norm(b.name) == want or norm(bossName(b.name)) == want then return b end
    local ln = learnedName(b.npcID)
    if ln and norm(ln) == want then return b end
    for _, a in API.ipairs(b.aliases or {}) do
      if norm(a) == want or norm(bossName(a)) == want then return b end
    end
  end
end
local function bossByNpc(d, id)
  if not d or not id then return nil end
  for _, b in API.ipairs(d.bosses or {}) do if b.npcID == id then return b end end
end

-- a boss's name for the list: OneForAll's translation, else the name this client gave it, else the English one
local function bossLabel(b)
  local n = bossName(b.name)
  if n == b.name then n = learnedName(b.npcID) or n end
  return n
end

-- which of our dungeons this instance is (nil: one we have no data for)
local function resolve(instID)
  local list = byInstance(instID)
  local found = API.FindCurrentDungeon()
  if #list > 0 then
    if found then for _, d in ipairs(list) do if d == found then return d end end end
    return list[1]
  end
  return found
end

-- Window -------------------------------------------------------------------------------------------------------------
local frame, rows, ticker = nil, {}, nil
local refresh, update -- below

local function savePos()
  local p, _, _, x, y = frame:GetPoint(1)
  setQol("pos", { p or "TOPRIGHT", floor((x or 0) + 0.5), floor((y or 0) + 0.5) })
end
local function placeFrame()
  local pos = qol("pos")
  frame:ClearAllPoints()
  if type(pos) == "table" and pos[1] then
    frame:SetPoint(pos[1], UIParent, pos[1], tonumber(pos[2]) or 0, tonumber(pos[3]) or 0)
  else
    frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -230, -220) -- left of the minimap and the quest tracker's top
  end
end
function R.ResetPosition()
  setQol("pos", nil)
  if frame then placeFrame() end
end

-- the same instance, all over again: no kills, the clock from 0 (keeps the dungeon, its window and its fold)
local function restart(cur)
  local _, kind = IsInInstance()
  cur.kills, cur.extra, cur.done, cur.doneAt, cur.active, cur.left, cur.hidden, cur.reset = {}, {}, nil, nil, 0, nil, nil, nil
  cur.xp, cur.money, cur.manual = 0, 0, nil
  cur.since = (kind == "party" or kind == "raid") and now() or nil
  update()
end
local function restartAsk()
  local r = run(); if not r then return end
  local function go()
    local cur = run(); if cur then restart(cur) end
  end
  W.Confirm(L["Start the clock again for this dungeon? The killed bosses are cleared."], go)
end

local function headTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText(L["Dungeon run"], 1, 0.82, 0.2)
  GameTooltip:AddLine(L["Drag: move the window"], 0.8, 0.8, 0.8)
  GameTooltip:AddLine(L["Click: fold or unfold the boss list"], 0.8, 0.8, 0.8)
  GameTooltip:AddLine(L["Right-click: start the clock again"], 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function build()
  local f = CreateFrame("Frame", "OneForAllDungeonTrackerFrame", UIParent)
  f:SetSize(WIDTH, 60); f:SetFrameStrata("MEDIUM"); f:SetClampedToScreen(true)
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePos() end)
  W.FramedPanel(f)
  -- the head: dungeon name (click folds the list), close button
  local head = CreateFrame("Button", nil, f)
  head:SetPoint("TOPLEFT", 8, -6); head:SetPoint("TOPRIGHT", -32, -6); head:SetHeight(20)
  head:RegisterForClicks("LeftButtonUp", "RightButtonUp"); head:RegisterForDrag("LeftButton")
  head:SetScript("OnDragStart", function() f:StartMoving() end)
  head:SetScript("OnDragStop", function() f:StopMovingOrSizing(); savePos() end)
  head:SetScript("OnClick", function(_, button)
    if button == "RightButton" then restartAsk() return end
    setQol("folded", not qol("folded")); refresh()
  end)
  head:SetScript("OnEnter", headTip); head:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.fold = head:CreateTexture(nil, "ARTWORK"); f.fold:SetSize(12, 12); f.fold:SetPoint("LEFT", 0, 0)
  f.title = W.FontString(head, "OVERLAY", "GameFontNormal"); f.title:SetPoint("LEFT", f.fold, "RIGHT", 5, 0)
  f.title:SetJustifyH("LEFT"); f.title:SetWordWrap(false)
  f.title:SetTextColor(W.SkinColor(1, 0.82, 0.20))
  -- reset, right after the dungeon's name (as in Dungeon Journal): the dungeon was reset and nothing told us. The
  -- game's own refresh button, as on the Looking For Group panel. Shown while the run goes on.
  local reset = CreateFrame("Button", nil, f)
  reset:SetSize(22, 22)
  reset:SetPoint("LEFT", f.title, "RIGHT", 3, 0)
  reset:SetFrameLevel(head:GetFrameLevel() + 5)
  reset:SetNormalTexture("Interface\\Buttons\\UI-SquareButton-Up")
  reset:SetPushedTexture("Interface\\Buttons\\UI-SquareButton-Down")
  reset:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  reset.icon = reset:CreateTexture(nil, "ARTWORK", nil, 5)
  W.SetTexture(reset.icon, "Interface\\Buttons\\UI-RefreshButton")
  reset.icon:SetSize(11, 11); reset.icon:SetPoint("CENTER", -0.5, 0)
  reset:SetScript("OnMouseDown", function(self) self.icon:SetPoint("CENTER", -1.5, -1) end)
  reset:SetScript("OnMouseUp", function(self) self.icon:SetPoint("CENTER", -0.5, 0) end)
  reset:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L["Reset the tracker"], 1, 0.82, 0)
    GameTooltip:AddLine(L["The dungeon was reset and the tracker didn't notice: the run starts again from zero (time, XP, gold and bosses)."], 1, 1, 1, true)
    GameTooltip:Show()
  end)
  reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
  reset:SetScript("OnClick", function() GameTooltip:Hide(); restartAsk() end)
  reset:Hide()
  f.reset = reset
  local close = W.CloseButton(f, function() R.SetHidden(true) end)
  if close then close:SetPoint("TOPRIGHT", -6, -6) end
  -- Time | XP earned | Gold: a small grey label over each value (placed in refresh, as the options leave them)
  f.cols = {}
  for _, key in ipairs({ "time", "xp", "gold" }) do
    local c = {}
    c.label = W.FontString(f, "OVERLAY", "GameFontDisableSmall")
    c.value = W.FontString(f, "OVERLAY", "GameFontHighlight")
    c.value:SetPoint("TOPLEFT", c.label, "BOTTOMLEFT", 0, -3)
    f.cols[key] = c
  end
  f.cols.time.label:SetText(L["Time"]); f.cols.xp.label:SetText(L["XP earned"]); f.cols.gold.label:SetText(L["Gold"])
  f.time = f.cols.time.value
  f.line = f:CreateTexture(nil, "ARTWORK"); f.line:SetHeight(1); f.line:SetColorTexture(0.50, 0.38, 0.19, 0.55)
  -- the boss count, at the top of the list
  f.count = W.FontString(f, "OVERLAY", "GameFontNormalSmall"); f.count:SetJustifyH("LEFT")
  f:Hide()
  frame = f
  placeFrame()
end

local function row(i)
  local r = rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, frame)
  r:SetSize(WIDTH - 20, ROW_H)
  r:RegisterForDrag("LeftButton")
  r:SetScript("OnDragStart", function() frame:StartMoving() end)
  r:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); savePos() end)
  r.hi = r:CreateTexture(nil, "BACKGROUND"); r.hi:SetAllPoints(); r.hi:SetColorTexture(0.90, 0.66, 0.22, 0.12); r.hi:Hide()
  r.mark = r:CreateTexture(nil, "ARTWORK"); r.mark:SetSize(12, 12); r.mark:SetPoint("LEFT", 0, 0)
  r.when = W.FontString(r, "OVERLAY", "GameFontHighlightSmall"); r.when:SetPoint("RIGHT", 0, 0); r.when:SetJustifyH("RIGHT")
  r.name = W.FontString(r, "OVERLAY", "GameFontHighlightSmall"); r.name:SetPoint("LEFT", 16, 0)
  r.name:SetPoint("RIGHT", r.when, "LEFT", -6, 0); r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
  r:SetScript("OnEnter", function(self)
    if not self.boss then return end
    self.hi:Show()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(self.label or "", 1, 0.82, 0.2)
    GameTooltip:AddLine(L["Click: open this boss in OneForAll."], 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function(self) self.hi:Hide(); GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self)
    local d = dungeonByKey(run() and run().key)
    if d and self.boss then API.OpenDungeon(d, self.boss) end
  end)
  rows[i] = r
  return r
end

local function stopTicker() if ticker then ticker:Cancel(); ticker = nil end end
local function startTicker()
  if ticker or not (C_Timer and C_Timer.NewTicker) then return end
  ticker = C_Timer.NewTicker(1, function()
    if not (frame and frame:IsShown()) then stopTicker() return end
    local r = run()
    if r and not r.done then frame.time:SetText(clock(elapsed(r))) end
    if r and frame.xpShown then frame.cols.xp.value:SetText(thousands(r.xp)) end
  end)
end

refresh = function()
  local r = run()
  if not frame or not r then return end
  local d = dungeonByKey(r.key)
  frame.title:SetText(d and dungeonName(d.name) or r.name or L["Dungeon run"])
  -- the name as wide as it is (cut short only when it has to), the reset button right after it while the run goes on
  local canReset = not r.done
  frame.reset:SetShown(canReset)
  frame.title:SetWidth(0)
  local full = (frame.title.GetUnboundedStringWidth and frame.title:GetUnboundedStringWidth()) or frame.title:GetStringWidth() or 0
  local room = WIDTH - 8 - 17 - 34 - (canReset and 26 or 0)
  frame.title:SetWidth(math.max(1, math.min((tonumber(full) or 0) + 1, room)))
  local folded = qol("folded") and true or false
  W.SetTexture(frame.fold, folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
  -- the list: our bosses in the data's order, then kills we have no entry for
  local list, killed, required, requiredDone = {}, 0, 0, 0
  r.kills = r.kills or {}
  for _, b in API.ipairs(d and d.bosses or {}) do
    local opt = optional(b)
    local t = r.kills[b.name]
    if not opt then required = required + 1; if t then requiredDone = requiredDone + 1 end end
    if t then killed = killed + 1 end
    if t or not opt then list[#list + 1] = { boss = b.name, label = bossLabel(b), t = t, opt = opt, rare = b.rare } end
  end
  for _, name in ipairs(r.extra or {}) do
    killed = killed + 1
    list[#list + 1] = { label = name, t = r.kills[name], opt = true }
  end
  -- Time | XP earned | Gold, less the ones the options hide (no XP at the level cap); none left: a slimmer window
  frame.time:SetText(clock(elapsed(r)))
  if r.done then frame.time:SetTextColor(0.25, 1.0, 0.35) else frame.time:SetTextColor(1, 1, 1) end
  frame.cols.xp.value:SetText(thousands(r.xp))
  frame.cols.gold.value:SetText(goldText(r.money))
  local cols = {}
  if not opt("hideTime") then cols[#cols + 1] = frame.cols.time end
  frame.xpShown = not capped() and not opt("hideXP")
  if frame.xpShown then cols[#cols + 1] = frame.cols.xp end
  if not opt("hideGold") then cols[#cols + 1] = frame.cols.gold end
  for _, c in pairs(frame.cols) do c.label:Hide(); c.value:Hide() end
  -- each column as wide as its label needs (a long one, "XP des mobs", no longer runs into the next one); spread out
  -- when there is room left
  local widths, total = {}, 0
  for i, c in ipairs(cols) do
    local lw = tonumber(c.label:GetStringWidth() or 0) or 0
    local vw = c == frame.cols.time and 46 or (tonumber(c.value:GetStringWidth() or 0) or 0)
    widths[i] = math.max(lw, vw, 40)
    total = total + widths[i]
  end
  local gap = #cols > 1 and math.max(12, math.floor((WIDTH - 20 - total) / (#cols - 1))) or 0
  local x = 10
  for i, c in ipairs(cols) do
    c.label:ClearAllPoints(); c.label:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -30)
    c.label:Show(); c.value:Show()
    x = x + widths[i] + gap
  end
  frame:SetWidth(math.max(WIDTH, x - gap + 10))
  local head = #cols > 0 and 62 or 30
  frame.line:ClearAllPoints(); frame.line:SetPoint("TOPLEFT", 10, -head); frame.line:SetPoint("TOPRIGHT", -10, -head)
  -- the bosses (Hide Bosses: none, nor their count)
  local bosses = not opt("hideBosses")
  frame.count:SetShown(bosses)
  frame.count:ClearAllPoints(); frame.count:SetPoint("TOPLEFT", 10, -(head + 5))
  if required > 0 then
    frame.count:SetText(L["Bosses"] .. "  |cffffffff" .. fmt(L["%d / %d bosses"], requiredDone, required) .. "|r" .. (killed > requiredDone and ("  |cff9d9d9d+" .. (killed - requiredDone) .. "|r") or ""))
  else
    frame.count:SetText(L["Bosses"] .. "  |cffffffff" .. fmt(L["%d bosses"], killed) .. "|r")
  end
  local top = head + 22
  local shown = (folded or not bosses) and 0 or #list
  for i = 1, math.max(shown, #rows) do
    local e = i <= shown and list[i]
    if e then
      local w = row(i)
      w:ClearAllPoints(); w:SetPoint("TOPLEFT", 10, -(top + (i - 1) * ROW_H))
      w.boss, w.label = e.boss, e.label
      local extra = e.opt and ("  |cff9d9d9d(" .. string.lower(L[e.rare and "Rare" or "Summoned"]) .. ")|r") or ""
      if e.opt and not e.boss then extra = "" end
      if e.t then
        W.SetTexture(w.mark, "Interface\\RaidFrame\\ReadyCheck-Ready"); w.mark:Show()
        w.name:SetText("|cff7fe07f" .. e.label .. "|r" .. extra)
        w.when:SetText(clock(e.t))
      else
        w.mark:Hide()
        w.name:SetText("|cffa0a0a0" .. e.label .. "|r" .. extra)
        w.when:SetText("")
      end
      w:Show()
    elseif rows[i] then
      rows[i]:Hide()
    end
  end
  frame.line:SetShown(#cols > 0 or bosses)
  frame:SetHeight(bosses and (top + shown * ROW_H + 4) or (#cols > 0 and head + 4 or 32))
  if r.done then stopTicker() else startTicker() end
end
R.Refresh = function() if frame and frame:IsShown() then refresh() end end

-- Shown by itself in a dungeon: with a group, or solo with "Show Tracker for solo runs too"; never with "Never track
-- dungeons"; not for a run whose tracker was closed (Hide Tracker). /ofa run shows it anyway.
local inside = false
local function shouldShow(r)
  if not (r and inside) or r.hidden then return false end
  if r.manual then return true end
  if opt("never") then return false end
  return inGroup() or opt("solo")
end
local function showWindow()
  local r = run()
  if not shouldShow(r) then if frame then frame:Hide() end stopTicker() return end
  if not frame then build() end
  frame:Show()
  refresh()
end

-- Kills --------------------------------------------------------------------------------------------------------------
local function checkDone(r, d)
  if r.done or not d then return end
  local required = 0
  for _, b in API.ipairs(d.bosses or {}) do
    if not optional(b) then
      required = required + 1
      if not r.kills[b.name] then return end
    end
  end
  if required == 0 then return end
  r.done = elapsed(r)
  r.active, r.since, r.doneAt = r.done, nil, now()
  say(fmt(L["%s completed in %s."], dungeonName(d.name), clock(r.done)))
  if PlaySound and SOUNDKIT and SOUNDKIT.UI_EPICLOOT_TOAST then pcall(PlaySound, SOUNDKIT.UI_EPICLOOT_TOAST) end
end

local function markKey(r, key)
  if r.kills[key] then return false end
  r.kills[key] = elapsed(r)
  return true
end

-- kills listed by a name we could not match then, that now stand for one of our bosses (a name learned since)
local function dropExtras(r, d)
  if not (r.extra and d) then return end
  for i = #r.extra, 1, -1 do
    local name = r.extra[i]
    local b = bossByName(d, name)
    if b then
      table.remove(r.extra, i)
      if not r.kills[b.name] then r.kills[b.name] = r.kills[name] end
      r.kills[name] = nil
      dlog("extra %s is %s", name, b.name)
    end
  end
end

-- an encounter name listed as an extra (BOSS_KILL can come before ENCOUNTER_END) once the fight told its boss
local function dropName(r, name)
  if not (r.extra and type(name) == "string") then return end
  for i = #r.extra, 1, -1 do
    if r.extra[i] == name then table.remove(r.extra, i); r.kills[name] = nil end
  end
end

-- a boss of this instance died, by NPC ID: in our dungeon or (shared instance IDs) in one of its siblings, which
-- then becomes the run's dungeon (Lower / Upper Blackrock Spire, the Dire Maul wings)
local function killedNpc(id)
  local r = run()
  if not (r and r.since and id) or r.done then return end
  local d = dungeonByKey(r.key)
  local b = bossByNpc(d, id)
  if not b then
    for _, other in ipairs(byInstance(r.id)) do
      b = bossByNpc(other, id)
      if b then r.key, d = other.name, other; break end
    end
  end
  if not b then return end
  if markKey(r, b.name) then
    dlog("kill by NPC %s -> %s", id, b.name)
    dropExtras(r, d)
    checkDone(r, d); R.Refresh()
  end
  return b
end

-- a kill by name (ENCOUNTER_END / BOSS_KILL): ours when it matches a boss, else listed as it comes
local function killedName(name, extraOk)
  local r = run()
  if not (r and r.since) or r.done or type(name) ~= "string" or secret(name) or name == "" then return end
  local d = dungeonByKey(r.key)
  local b = bossByName(d, name)
  if not b then
    for _, other in ipairs(byInstance(r.id)) do
      b = bossByName(other, name)
      if b then r.key, d = other.name, other; break end
    end
  end
  if b then
    if markKey(r, b.name) then dlog("kill by name %s -> %s", name, b.name); checkDone(r, d); R.Refresh() end
    return b
  end
  if extraOk == false then return nil end
  r.extra = r.extra or {}
  if markKey(r, name) then dlog("kill not matched: %s (listed as is)", name); table.insert(r.extra, name); R.Refresh() end
end

local encounter, encounterStart, encounterEnd

-- a unit: when it is a dead boss, a kill; a living boss of a sibling dungeon makes that the run's dungeon
local function checkUnit(unit)
  local r = run()
  if not (r and r.since) or r.done or type(unit) ~= "string" then return end
  if not (UnitExists and UnitExists(unit)) then return end
  local guid = UnitGUID and UnitGUID(unit)
  local id = npcOf(guid)
  if not id then return end
  local d0 = dungeonByKey(r.key)
  local known = bossByNpc(d0, id)
  if not known then
    for _, other in ipairs(byInstance(r.id)) do known = known or bossByNpc(other, id) end
  end
  if known then
    local uname = UnitName and UnitName(unit)
    if type(uname) == "string" and not secret(uname) and learnedName(id) ~= uname then
      learnName(id, uname); dlog("name of %s (%s): %s", known.name, id, uname)
    end
    if encounter and not encounter.npcs[id] then
      encounter.npcs[id] = true; dlog("encounter %s: boss %s (%s) seen as %s", encounter.id, known.name, id, unit)
    end
  end
  local dead = UnitIsDead and UnitIsDead(unit)
  if secret(dead) then return end
  if dead then killedNpc(id) return end
  -- a boss ticked as killed, alive again and untouched: the instance was reset (by anyone in the group) - a new run.
  -- Only when the unit's name is the boss's own name: an entry for a group of mobs ("Atal'ai Defenders") shares its
  -- NPC ID with the others of the group, which are still alive after the first one fell
  local mine = bossByNpc(dungeonByKey(r.key), id)
  if mine and r.kills[mine.name] then
    local uname = UnitName and UnitName(unit)
    local hp, hpMax = UnitHealth and UnitHealth(unit), UnitHealthMax and UnitHealthMax(unit)
    if type(uname) == "string" and not secret(uname, hp, hpMax) and hp and hpMax and hpMax > 0 and hp >= hpMax
      and bossByName(dungeonByKey(r.key), uname) == mine then
      restart(r)
      say(L["This boss is alive again: the instance was reset, the dungeon run starts again."])
    end
    return
  end
  local list = byInstance(r.id)
  if #list > 1 and not bossByNpc(dungeonByKey(r.key), id) then
    for _, other in ipairs(list) do
      if bossByNpc(other, id) and not next(r.kills) then r.key = other.name; R.Refresh(); break end
    end
  end
end

-- the fight in progress (ENCOUNTER_START): its ID and the boss NPC IDs seen during it
function encounterStart(id, name)
  if secret(id) then id = nil end
  encounter = { id = id, name = name, npcs = {} }
  dlog("ENCOUNTER_START id=%s name=%s", id, name)
  for i = 1, 5 do
    local u = "boss" .. i
    if UnitExists and UnitExists(u) then dlog("  %s: npc %s, %s", u, npcOf(UnitGUID and UnitGUID(u)), UnitName and UnitName(u)) end
    checkUnit(u)
  end
  checkUnit("target")
end
function encounterEnd(id, name, success)
  dlog("ENCOUNTER_END id=%s name=%s success=%s", id, name, success)
  local cur = encounter
  encounter = nil
  if success ~= 1 then return end
  local r = run()
  if not (r and r.since) or r.done then return end
  local db = acctDB()
  if secret(id) then id = nil end
  -- 1. an encounter met before: its boss
  local npc = id and db.encounters[id]
  if npc and (killedNpc(npc) or bossByNpc(dungeonByKey(r.key), npc)) then
    dropName(r, name); R.Refresh() return
  end
  -- 2. the name matches one of our bosses
  local b = killedName(name, false)
  if b then
    if id and b.npcID then db.encounters[id] = b.npcID end
    return
  end
  -- 3. the bosses seen during this fight
  local hit
  if cur and (cur.id == nil or cur.id == id) then
    for n in pairs(cur.npcs) do
      local got = killedNpc(n)
      if got or bossByNpc(dungeonByKey(r.key), n) then
        hit = n
        if id then db.encounters[id] = n end
        if not learnedName(n) then learnName(n, name) end
      end
    end
  end
  if hit then dropName(r, name); dropExtras(r, dungeonByKey(r.key)); R.Refresh() return end
  -- 4. nothing: listed under its own name
  killedName(name)
end

local function checkLoot()
  if not GetLootSourceInfo or not GetNumLootItems then return end
  for slot = 1, GetNumLootItems() or 0 do
    local src = { pcall(GetLootSourceInfo, slot) }
    if src[1] then
      for i = 2, #src, 2 do killedNpc(npcOf(src[i])) end
    end
  end
end

-- the group's targets and the boss frames, once a second while inside (bosses that die while nobody of ours looks at
-- them through a unit we get events for)
local SCAN = { "target", "focus", "boss1", "boss2", "boss3", "boss4", "boss5" }
local function scan()
  for _, u in ipairs(SCAN) do checkUnit(u) end
  if IsInRaid and IsInRaid() then
    for i = 1, (GetNumGroupMembers and GetNumGroupMembers() or 0) do checkUnit("raid" .. i .. "target") end
  elseif IsInGroup and IsInGroup() then
    for i = 1, 4 do checkUnit("party" .. i .. "target") end
  end
end

-- Entering and leaving -----------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local UNIT_EVENTS = { "ENCOUNTER_START", "ENCOUNTER_END", "INSTANCE_ENCOUNTER_ENGAGE_UNIT", "BOSS_KILL", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT",
  "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "LOOT_OPENED" }
local scanTicker
local function listen(on)
  for _, e in ipairs(UNIT_EVENTS) do
    if on then pcall(ev.RegisterEvent, ev, e) else pcall(ev.UnregisterEvent, ev, e) end
  end
  if on and not scanTicker and C_Timer and C_Timer.NewTicker then
    scanTicker = C_Timer.NewTicker(1, function() safe("DungeonTrackerScan", scan) end)
  elseif not on and scanTicker then
    scanTicker:Cancel(); scanTicker = nil
  end
end

-- logout: also on /reload, so a finished run is not marked as left (it would start again after the reload)
local function leave(quiet, logout)
  local r = run()
  if not r then return end
  if not r.since then
    if r.done and not r.left and not logout then r.left = now() end
    return
  end
  r.active = (r.active or 0) + math.max(0, now() - r.since)
  r.since, r.left = nil, now()
  if not quiet and not r.done then
    local d = dungeonByKey(r.key)
    local killed = 0
    for _ in pairs(r.kills or {}) do killed = killed + 1 end
    if killed > 0 then
      local name = d and dungeonName(d.name) or r.name or "?"
      say(fmt(L["%s: %d bosses killed, %s in the dungeon."], name, killed, clock(r.active)))
    end
  end
end

update = function()
  local kind
  if IsInInstance then inside, kind = IsInInstance() end
  inside = inside and (kind == "party" or kind == "raid") and true or false
  if not inside then
    leave(false)
    listen(false)
    if frame then frame:Hide() end
    stopTicker()
    return
  end
  local name, _, _, _, _, _, _, instID = GetInstanceInfo()
  if secret(instID) then instID = nil end
  local r = run()
  local t = now()
  local fresh = not r or r.id ~= instID or r.reset
    or (not r.done and not r.since and r.left and t - r.left > RESUME)
    or (r.done and (r.left or t - (r.doneAt or 0) > 4 * RESUME))
  if fresh then
    local d = resolve(instID)
    r = { id = instID, key = d and d.name or nil, name = (type(name) == "string" and not secret(name)) and name or nil,
      active = 0, since = t, kills = {}, extra = {} }
    charDB().run = r
  elseif not r.since and not r.done then
    r.since, r.left = t, nil -- back inside: the clock goes on
  elseif r.done then
    r.left = nil
  end
  if not r.key then local d = resolve(instID); if d then r.key = d.name end
  elseif not next(r.kills or {}) then
    -- Scarlet Monastery: OneForAll tells the wing (by the place name on the minimap since 6.2.10) once it is there.
    -- Since 6.2.11 it also says when it only guesses (a corridor without a known place name): then the wing stays
    local found, sure = API.FindCurrentDungeon()
    if sure == false then found = nil end
    for _, d in ipairs(found and byInstance(instID) or {}) do
      if d == found then r.key = found.name; break end
    end
  end
  dlog("in %s (instance %s) as %s%s", r.name, instID, r.key, fresh and ", new run" or "")
  listen(not r.done)
  showWindow()
end

ev:SetScript("OnEvent", function(_, event, a1, a2, _, _, a5)
  local fn
  if event == "PLAYER_ENTERING_WORLD" then
    fn = function()
      R.InitCounters()
      update()
    end
  elseif event == "ZONE_CHANGED_NEW_AREA" then fn = update
  elseif event == "GROUP_ROSTER_UPDATE" then fn = function() if inside then showWindow() end end
  elseif event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then fn = R.OnXP
  elseif event == "QUEST_TURNED_IN" then fn = function() R.OnQuest(a2) end
  elseif event == "PLAYER_MONEY" then fn = R.OnMoney
  elseif event == "PLAYER_LOGOUT" then fn = function() leave(true, true) end
  elseif event == "ENCOUNTER_START" then fn = function() encounterStart(a1, a2) end
  elseif event == "ENCOUNTER_END" then fn = function() encounterEnd(a1, a2, a5) end
  elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
    fn = function() for i = 1, 5 do checkUnit("boss" .. i) end end
  elseif event == "BOSS_KILL" then
    fn = function()
      dlog("BOSS_KILL id=%s name=%s", a1, a2)
      local npc = not secret(a1) and a1 and acctDB().encounters[a1]
      if not (npc and killedNpc(npc)) then killedName(a2) end
    end
  elseif event == "CHAT_MSG_SYSTEM" then fn = function() R.SystemMessage(a1) end
  elseif event == "PLAYER_TARGET_CHANGED" then fn = function() checkUnit("target") end
  elseif event == "UPDATE_MOUSEOVER_UNIT" then fn = function() checkUnit("mouseover") end
  elseif event == "LOOT_OPENED" then fn = checkLoot
  elseif event == "UNIT_HEALTH" or event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
    if type(a1) == "string" and (a1:find("^nameplate") or a1:find("^boss") or a1 == "target" or a1 == "focus") then
      fn = function() checkUnit(a1) end
    end
  end
  if fn then safe("DungeonTracker", fn) end
end)

-- XP and money while inside ------------------------------------------------------------------------------------------
local lastXP, lastMax, lastLevel, lastMoney
local questXP, questClock, gainXP, gainClock = 0, 0, 0, 0
local function readXP()
  if not (UnitXP and UnitXPMax and UnitLevel) then return nil end
  local xp, max, lvl = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  if secret(xp, max, lvl) or type(xp) ~= "number" or type(max) ~= "number" or type(lvl) ~= "number" then return nil end
  return xp, max, lvl
end
local function readMoney()
  local m = GetMoney and GetMoney()
  if type(m) ~= "number" or secret(m) then return nil end
  return m
end
local function clockNow() return GetTime and GetTime() or now() end
local function countable() local r = run(); return inside and r or nil end
-- the values to count from (at login, after the loading screen)
function R.InitCounters()
  if not lastXP then lastXP, lastMax, lastLevel = readXP() end
  if not lastMoney then lastMoney = readMoney() end
end
function R.OnXP()
  local xp, max, lvl = readXP()
  if not xp then return end
  local gain = 0
  if lastXP and lastLevel then
    if lvl > lastLevel then gain = (lastMax or 0) - lastXP + xp
    elseif lvl == lastLevel and xp > lastXP then gain = xp - lastXP end
  end
  lastXP, lastMax, lastLevel = xp, max, lvl
  local r = countable()
  if gain <= 0 or not r then return end
  -- a quest turned in just before: its XP is not the mobs'
  if clockNow() - questClock <= 3 and questXP > 0 then
    local used = math.min(gain, questXP); questXP = questXP - used; gain = gain - used
  end
  r.xp = (r.xp or 0) + gain
  gainXP, gainClock = gain, clockNow()
  R.Refresh()
end
-- QUEST_TURNED_IN comes before or after the XP it gives: take it back from the last gain, or keep it for the next one
function R.OnQuest(xp)
  xp = tonumber(xp)
  if not xp or xp <= 0 or secret(xp) then return end
  local r = countable()
  if not r then return end
  if clockNow() - gainClock <= 3 and gainXP > 0 then
    local used = math.min(xp, gainXP, r.xp or 0); r.xp = (r.xp or 0) - used; gainXP = gainXP - used; xp = xp - used
    R.Refresh()
  end
  if xp > 0 then questXP, questClock = xp, clockNow() end
end
function R.OnMoney()
  local m = readMoney()
  if not m then return end
  local before = lastMoney
  lastMoney = m
  local r = countable()
  if not (before and r) or m <= before then return end
  r.money = (r.money or 0) + (m - before)
  R.Refresh()
end

-- "Ragefire Chasm has been reset." (the game's INSTANCE_RESET_SUCCESS, in the client's language): the next time inside
-- is a new run, even within the 30 minutes. Only while outside (the reset is only possible there).
local resetPattern
function R.SystemMessage(text)
  if type(text) ~= "string" or secret(text) then return end
  local r = run()
  if not r or r.since then return end
  if resetPattern == nil then
    local g = type(INSTANCE_RESET_SUCCESS) == "string" and INSTANCE_RESET_SUCCESS or "%s has been reset."
    resetPattern = "^" .. g:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%s", "(.+)") .. "$"
  end
  local name = text:match(resetPattern)
  if not name then return end
  -- the reset names the instance; when we know our run's name, only that one (one reset can name several)
  if r.name and norm(name) ~= norm(r.name) then return end
  r.reset = true
end

-- the options (OneForAll > Plugins > Dungeon Tracker)
function R.Apply() update() end
R.OPTIONS = { "never", "solo", "hideTime", "hideXP", "hideGold",
  "hideBosses" }
-- Hide Tracker: the current run's tracker closed (as with its X); unticked, it comes back
function R.IsHidden() local r = run(); return r and r.hidden and true or false end
function R.SetHidden(on)
  local r = run()
  if not r then return end
  r.hidden = on and true or nil
  if on then r.manual = nil; if frame then frame:Hide() end stopTicker() else showWindow() end
end

-- /ofa run: show / hide the window inside; /ofa run reset: start the clock again
function R.Slash(arg)
  if arg == "debug" then
    local db = acctDB()
    db.debug = not db.debug or nil
    say(db.debug and L["Dungeon Tracker log shown in the chat. /ofa run debug again to hide it."]
      or L["Dungeon Tracker log hidden from the chat (still saved)."])
    return
  end
  local r = run()
  local inside = IsInInstance and select(2, IsInInstance())
  if not (r and (r.since or r.done) and (inside == "party" or inside == "raid")) then say(L["Not in a dungeon."]) return end
  if arg == "reset" then restartAsk() return end
  if frame and frame:IsShown() then R.SetHidden(true)
  else r.hidden, r.manual = nil, true; showWindow() end
end

ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_LOGOUT")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP", "QUEST_TURNED_IN", "PLAYER_MONEY" }) do
  pcall(ev.RegisterEvent, ev, e)
end

-- OneForAll: options from the earlier builds, the Settings section and /ofa run -----------------------------------
-- the OneForAll builds with the tracker built in (6.2.x-dt) kept its options among OneForAll's own: taken over once
if not opts:Get("migrated") then
  for _, k in ipairs({ "Never", "Solo", "HideTime", "HideXP", "HideGold", "HideBosses", "Folded", "Pos" }) do
    local v = API.GetOption("dungeonRun" .. k)
    if v ~= nil then opts:Set(k:sub(1, 1):lower() .. k:sub(2), type(v) == "table" and API.Copy(v) or v) end
  end
  opts:Set("migrated", true)
end
for _, k in ipairs(R.OPTIONS) do opts:OnChanged(k, R.Apply) end

-- its options, on OneForAll's Plugins page
API.AddSettingsSection(ADDON, { title = L["Dungeon Tracker"], icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
  build = function(s)
    local function get(key) return function() return opts:Get(key) and true or false end end
    local function set(key) return function(v) opts:Set(key, v and true or false) end end
    local list = {
      { L["Hide Tracker"], L["Hides the tracker for this run. Closing it with its X ticks this; a new run unticks it by itself. /ofa run or unticking it shows the tracker again."],
        R.IsHidden, R.SetHidden },
      { L["Never track dungeons"], L["The small tracker window (time, XP, gold and bosses) never opens by itself in dungeons. Runs are still recorded, and /ofa run still opens it."],
        get("never"), set("never") },
      { L["Show Tracker for solo runs too"], L["The tracker also opens by itself when you are in a dungeon without a group."],
        get("solo"), set("solo") },
      { L["Hide Bosses"], L["The tracker doesn't show the boss list."], get("hideBosses"), set("hideBosses") },
      { L["Hide Time"], L["The tracker doesn't show the run's time."], get("hideTime"), set("hideTime") },
      { L["Hide XP"], L["The tracker doesn't show the XP from mobs."], get("hideXP"), set("hideXP") },
      { L["Hide Gold"], L["The tracker doesn't show the money earned."], get("hideGold"), set("hideGold") },
    }
    for i = 1, #list, 2 do
      local a, b = list[i], list[i + 1]
      -- two switches side by side, spread over the section's width
      local half = math.floor((s.width or 488) / 2)
      s:check(a[1], a[2], a[3], a[4], 0, true, half - 50)
      if b then s:check(b[1], b[2], b[3], b[4], half, true, half - 50) end
      s:nextRow()
    end
    s:button(L["Reset tracker position"], 190, R.ResetPosition)
    s:nextRow()
  end })

API.RegisterSlashCommand("run", function(rest)
  rest = (rest or ""):lower()
  R.Slash((rest == "reset" or rest == "debug") and rest or nil)
end, "/ofa run: show or hide the dungeon tracker; /ofa run reset: start it again; /ofa run debug: show its log in the chat")
