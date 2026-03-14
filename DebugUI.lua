local addonName, addon = ...

local DEBUG_FRAME_WIDTH = 760
local DEBUG_FRAME_HEIGHT = 520

local function ResolveGlobalPath(path)
    if not path or path == "" then
        return nil
    end

    local current = _G
    for part in string.gmatch(path, "[^%.]+") do
        if type(current) ~= "table" then
            return nil
        end

        current = current[part]
        if current == nil then
            return nil
        end
    end

    return current
end

local function CanAccessDebugValue(value)
    if canaccessvalue then
        local ok, accessible = pcall(canaccessvalue, value)
        if ok then
            return accessible
        end
    end

    if issecretvalue then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret then
            return false
        end
    end

    return true
end

local function FormatDebugValue(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if value == nil then
        return "nil"
    end

    if not CanAccessDebugValue(value) then
        return "<secret>"
    end

    local valueType = type(value)
    if valueType == "string" then
        return string.format("%q", value)
    end

    if valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end

    if valueType == "function" then
        return "<function>"
    end

    if valueType ~= "table" then
        return tostring(value)
    end

    if seen[value] then
        return "<cycle>"
    end

    if depth >= 4 then
        return "<table>"
    end

    seen[value] = true
    local parts = {}
    for key, innerValue in pairs(value) do
        parts[#parts + 1] = "[" .. FormatDebugValue(key, depth + 1, seen) .. "]=" .. FormatDebugValue(innerValue, depth + 1, seen)
    end
    seen[value] = nil

    return "{ " .. table.concat(parts, ", ") .. " }"
end

local function PackResults(...)
    return {
        n = select("#", ...),
        ...
    }
end

local function SplitArgumentString(text)
    local result = {}
    local current = {}
    local quote = nil
    local escape = false

    for i = 1, #text do
        local ch = text:sub(i, i)
        if escape then
            current[#current + 1] = ch
            escape = false
        elseif ch == "\\" then
            current[#current + 1] = ch
            escape = true
        elseif quote then
            current[#current + 1] = ch
            if ch == quote then
                quote = nil
            end
        elseif ch == "\"" or ch == "'" then
            current[#current + 1] = ch
            quote = ch
        elseif ch == "," then
            result[#result + 1] = table.concat(current)
            current = {}
        else
            current[#current + 1] = ch
        end
    end

    if #current > 0 or text:find(",", 1, true) then
        result[#result + 1] = table.concat(current)
    end

    return result
end

local function ParseArgumentToken(token)
    token = strtrim(token or "")
    if token == "" then
        return nil, false
    end

    if token == "true" then
        return true, true
    end

    if token == "false" then
        return false, true
    end

    if token == "nil" then
        return nil, true
    end

    local numberValue = tonumber(token)
    if numberValue ~= nil then
        return numberValue, true
    end

    local quote = token:sub(1, 1)
    if (quote == "\"" or quote == "'") and token:sub(-1) == quote and #token >= 2 then
        return token:sub(2, -2), true
    end

    local resolved = ResolveGlobalPath(token)
    if resolved ~= nil then
        return resolved, true
    end

    return token, true
end

local function ParseArguments(text)
    local args = {}
    local tokens = SplitArgumentString(text or "")
    for _, token in ipairs(tokens) do
        local value, hasValue = ParseArgumentToken(token)
        if hasValue then
            args[#args + 1] = value
        end
    end
    return args
end

local function CreateScrollableOutput(parent, width, height)
    local holder = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    holder:SetSize(width, height)
    holder:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    holder:SetBackdropColor(0.08, 0.08, 0.08, 1)
    holder:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)

    local scroll = CreateFrame("ScrollFrame", nil, holder)
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maxRange = self:GetVerticalScrollRange()
        local nextValue = math.max(0, math.min(maxRange, current - delta * 24))
        self:SetVerticalScroll(nextValue)
    end)

    local edit = CreateFrame("EditBox", nil, scroll, "InputBoxTemplate")
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetWidth(width - 32)
    edit:SetFontObject(ChatFontNormal)
    edit:SetTextInsets(6, 6, 6, 6)
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    edit:SetScript("OnTextChanged", function(self)
        self:SetHeight(math.max(self:GetStringHeight() + 16, height - 24))
    end)

    scroll:SetScrollChild(edit)
    holder.scroll = scroll
    holder.edit = edit
    return holder
end

local function SetOutput(frame, text)
    frame.output.edit:SetText(text or "")
    frame.output.edit:SetCursorPosition(0)
    frame.output.scroll:SetVerticalScroll(0)
end

local function GetFirstTrackedSpellId()
    if not addon.db then
        return nil
    end

    for spellId, enabled in pairs(addon.db.trackedSpells or {}) do
        if enabled then
            return tonumber(spellId)
        end
    end

    for spellId, enabled in pairs(addon.db.manualSpells or {}) do
        if enabled then
            return tonumber(spellId)
        end
    end

    return nil
end

local function RunApiCall(frame)
    local methodPath = strtrim(frame.methodEdit:GetText() or "")
    local argsText = frame.argsEdit:GetText() or ""

    if methodPath == "" then
        SetOutput(frame, "Method is empty.")
        return
    end

    local fn = ResolveGlobalPath(methodPath)
    if type(fn) ~= "function" then
        SetOutput(frame, "Method not found or not callable: " .. methodPath)
        return
    end

    local args = ParseArguments(argsText)
    local results = PackResults(pcall(fn, unpack(args)))
    local lines = {}
    lines[#lines + 1] = "method = " .. methodPath
    lines[#lines + 1] = "args = " .. argsText
    lines[#lines + 1] = "ok = " .. tostring(results[1])

    if not results[1] then
        lines[#lines + 1] = "error = " .. tostring(results[2])
        SetOutput(frame, table.concat(lines, "\n"))
        return
    end

    if results.n == 1 then
        lines[#lines + 1] = "returns = <none>"
    else
        for i = 2, results.n do
            lines[#lines + 1] = "return[" .. tostring(i - 1) .. "] = " .. FormatDebugValue(results[i])
        end
    end

    SetOutput(frame, table.concat(lines, "\n"))
end

function addon:CreateApiDebugFrame()
    local frame = CreateFrame("Frame", "DebuffTrackApiDebugFrame", UIParent, "BackdropTemplate")
    frame:SetSize(DEBUG_FRAME_WIDTH, DEBUG_FRAME_HEIGHT)
    frame:SetPoint("CENTER", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.06, 0.06, 0.06, 0.96)
    frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    tinsert(UISpecialFrames, "DebuffTrackApiDebugFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("|cff00ccffDebuff Tracker|r API Debug")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local methodLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    methodLabel:SetPoint("TOPLEFT", 16, -46)
    methodLabel:SetText("Method")

    local methodEdit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    methodEdit:SetSize(500, 28)
    methodEdit:SetPoint("TOPLEFT", methodLabel, "BOTTOMLEFT", 6, -8)
    methodEdit:SetAutoFocus(false)
    methodEdit:SetText("C_UnitAuras.GetUnitAuraBySpellID")
    frame.methodEdit = methodEdit

    local argsLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    argsLabel:SetPoint("TOPLEFT", methodEdit, "BOTTOMLEFT", -6, -18)
    argsLabel:SetText("Args")

    local argsEdit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    argsEdit:SetSize(500, 28)
    argsEdit:SetPoint("TOPLEFT", argsLabel, "BOTTOMLEFT", 6, -8)
    argsEdit:SetAutoFocus(false)
    frame.argsEdit = argsEdit

    local runButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    runButton:SetSize(90, 28)
    runButton:SetPoint("LEFT", methodEdit, "RIGHT", 12, 0)
    runButton:SetText("Run")
    runButton:SetScript("OnClick", function()
        RunApiCall(frame)
    end)

    local fillButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    fillButton:SetSize(90, 28)
    fillButton:SetPoint("LEFT", argsEdit, "RIGHT", 12, 0)
    fillButton:SetText("Use Track")
    fillButton:SetScript("OnClick", function()
        local spellId = GetFirstTrackedSpellId()
        if spellId then
            frame.argsEdit:SetText(string.format("%q, %d", "player", spellId))
        else
            frame.argsEdit:SetText(string.format("%q, %d", "player", 1251594))
        end
    end)

    argsEdit:SetScript("OnEnterPressed", function()
        RunApiCall(frame)
    end)
    methodEdit:SetScript("OnEnterPressed", function()
        RunApiCall(frame)
    end)

    local helpText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    helpText:SetPoint("TOPLEFT", argsEdit, "BOTTOMLEFT", -6, -14)
    helpText:SetText("Examples: C_UnitAuras.GetUnitAuraBySpellID  |  args: \"player\", 1251594")

    frame.output = CreateScrollableOutput(frame, DEBUG_FRAME_WIDTH - 32, DEBUG_FRAME_HEIGHT - 190)
    frame.output:SetPoint("TOPLEFT", helpText, "BOTTOMLEFT", 0, -14)

    fillButton:GetScript("OnClick")()
    SetOutput(frame, "Write a method path and args, then press Run.")
    return frame
end

function addon:OpenApiDebugFrame()
    if not addon.ApiDebugFrame then
        addon.ApiDebugFrame = addon:CreateApiDebugFrame()
    end

    addon.ApiDebugFrame:Show()
end
