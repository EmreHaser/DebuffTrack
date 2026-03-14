local addonName, addon = ...

local FRAME_WIDTH = 780
local FRAME_HEIGHT = 620
local CONTENT_WIDTH = FRAME_WIDTH - 56
local DEFAULT_AURA_FILTER = "HARMFUL|RAID"

local FILTER_TOKENS = {
    { token = "HELPFUL", label = "Helpful", summary = "Returns helpful auras only." },
    { token = "HARMFUL", label = "Harmful", summary = "Returns harmful auras only." },
    { token = "PLAYER", label = "Player", summary = "Limits results to auras applied by the player." },
    { token = "RAID", label = "Raid", summary = "Uses Blizzard's raid-oriented aura filter." },
    { token = "CANCELABLE", label = "Cancelable", summary = "Returns cancelable buffs only." },
    { token = "NOT_CANCELABLE", label = "Not Cancelable", summary = "Returns buffs that cannot be canceled." },
    { token = "INCLUDE_NAME_PLATE_ONLY", label = "Nameplate Only", summary = "Includes auras flagged for nameplates only." },
    { token = "MAW", label = "Maw", summary = "Returns Torghast anima power auras." },
    { token = "EXTERNAL_DEFENSIVE", label = "External Defensive", summary = "Returns external defensive buffs." },
    { token = "CROWD_CONTROL", label = "Crowd Control", summary = "Returns crowd control effects." },
    { token = "RAID_IN_COMBAT", label = "Raid In Combat", summary = "Returns raid-frame combat auras." },
    { token = "RAID_PLAYER_DISPELLABLE", label = "Dispellable", summary = "Returns auras the player can dispel." },
    { token = "BIG_DEFENSIVE", label = "Big Defensive", summary = "Returns major defensive buffs." },
    { token = "IMPORTANT", label = "Important", summary = "Returns spells marked important by Blizzard." },
}

local TOKEN_ORDER = {}
local TOKEN_META = {}
for index, item in ipairs(FILTER_TOKENS) do
    TOKEN_ORDER[item.token] = index
    TOKEN_META[item.token] = item
end

local function CreateScrollableFrame(parent)
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local current = self:GetVerticalScroll()
        local maximum = self:GetVerticalScrollRange()
        local nextValue = math.max(0, math.min(maximum, current - delta * 40))
        self:SetVerticalScroll(nextValue)
    end)
    return scrollFrame
end

local function ClampByte(value)
    value = tonumber(value) or 0
    if value < 0 then
        return 0
    end
    if value > 255 then
        return 255
    end
    return math.floor(value + 0.5)
end

local function GetDbAuraFilter()
    local filter = addon and addon.db and addon.db.auraFilter or nil
    if type(filter) == "string" then
        filter = strtrim(filter)
    end

    if filter and filter ~= "" then
        return filter
    end

    return DEFAULT_AURA_FILTER
end

local function GetDbBorderColor()
    local color = addon and addon.db and addon.db.customBorderColor or nil
    if type(color) ~= "table" then
        return 0, 0, 0
    end

    local function Normalize(component)
        component = tonumber(component) or 0
        if component < 0 then
            return 0
        end
        if component > 1 then
            return 1
        end
        return component
    end

    return Normalize(color.r), Normalize(color.g), Normalize(color.b)
end

local function ParseFilterTokens(value)
    local order = {}
    local set = {}

    if type(value) ~= "string" then
        return order, set
    end

    for token in string.gmatch(string.upper(value), "[A-Z_]+") do
        if not set[token] then
            set[token] = true
            order[#order + 1] = token
        end
    end

    table.sort(order, function(left, right)
        local leftOrder = TOKEN_ORDER[left] or 999
        local rightOrder = TOKEN_ORDER[right] or 999
        if leftOrder == rightOrder then
            return left < right
        end
        return leftOrder < rightOrder
    end)

    return order, set
end

local function NormalizeFilterValue(value, allowEmpty)
    local order = ParseFilterTokens(value)
    if #order == 0 then
        return allowEmpty and "" or DEFAULT_AURA_FILTER
    end

    return table.concat(order, "|")
end

local function CreateWrappedText(parent, text, width, fontObject)
    local label = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlightSmall")
    if label.SetJustifyH then
        label:SetJustifyH("LEFT")
    end
    if label.SetJustifyV then
        label:SetJustifyV("TOP")
    end
    if label.SetWidth then
        label:SetWidth(width)
    end
    label:SetText(text)
    return label
end

local function CreateSection(parent, topOffset, height, titleText, descriptionText)
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    section:SetPoint("TOPLEFT", 0, topOffset)
    section:SetSize(CONTENT_WIDTH, height)
    section:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    section:SetBackdropColor(0.07, 0.07, 0.08, 0.94)
    section:SetBackdropBorderColor(0.22, 0.22, 0.24, 1)

    if titleText and titleText ~= "" then
        local title = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 16, -14)
        title:SetText(titleText)
    end

    if descriptionText and descriptionText ~= "" then
        local description = CreateWrappedText(section, descriptionText, CONTENT_WIDTH - 32, "GameFontHighlightSmall")
        description:SetPoint("TOPLEFT", 16, -36)

        section.contentTop = -52 - (description.GetStringHeight and description:GetStringHeight() or 0)
        if section.contentTop > -58 then
            section.contentTop = -58
        end
    else
        section.contentTop = -18
    end

    return section
end

local function UpdateButtonVisual(button)
    if not button or not button.bg or not button.border then
        return
    end

    if button.isSelected then
        button.bg:SetColorTexture(0.18, 0.18, 0.10, 0.95)
        button.border:SetColorTexture(0.95, 0.78, 0.22, 1)
        if button.label then
            button.label:SetTextColor(1.0, 0.88, 0.35)
        end
        return
    end

    if button.isHovered then
        button.bg:SetColorTexture(0.10, 0.12, 0.16, 0.95)
        button.border:SetColorTexture(0.42, 0.48, 0.56, 1)
        if button.label then
            button.label:SetTextColor(0.95, 0.95, 0.95)
        end
        return
    end

    button.bg:SetColorTexture(0.05, 0.06, 0.08, 0.95)
    button.border:SetColorTexture(0.20, 0.24, 0.30, 1)
    if button.label then
        button.label:SetTextColor(0.86, 0.86, 0.86)
    end
end

local function CreateFlatButton(parent, width, height, text)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    button.bg = bg

    local border = button:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT")
    border:SetPoint("TOPRIGHT")
    border:SetHeight(1)
    button.borderTop = border

    local borderBottom = button:CreateTexture(nil, "BORDER")
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(1)
    button.borderBottom = borderBottom

    local borderLeft = button:CreateTexture(nil, "BORDER")
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(1)
    button.borderLeft = borderLeft

    local borderRight = button:CreateTexture(nil, "BORDER")
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(1)
    button.borderRight = borderRight

    button.border = {
        SetColorTexture = function(_, r, g, b, a)
            button.borderTop:SetColorTexture(r, g, b, a)
            button.borderBottom:SetColorTexture(r, g, b, a)
            button.borderLeft:SetColorTexture(r, g, b, a)
            button.borderRight:SetColorTexture(r, g, b, a)
        end,
    }

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    button.label = label

    button:SetScript("OnEnter", function(self)
        self.isHovered = true
        UpdateButtonVisual(self)
        if self.tooltipTitle or self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.tooltipTitle then
                GameTooltip:AddLine(self.tooltipTitle, 1, 0.82, 0.15)
            end
            if self.tooltipText then
                GameTooltip:AddLine(self.tooltipText, 0.92, 0.92, 0.92, true)
            end
            GameTooltip:Show()
        end
    end)
    button:SetScript("OnLeave", function(self)
        self.isHovered = false
        UpdateButtonVisual(self)
        GameTooltip:Hide()
    end)

    function button:SetSelected(selected)
        self.isSelected = selected == true
        UpdateButtonVisual(self)
    end

    function button:SetLabel(value)
        self.label:SetText(value)
    end

    button:SetSelected(false)
    return button
end

local function SetEditBoxEnabled(editBox, enabled)
    if not editBox then
        return
    end

    if editBox.SetEnabled then
        editBox:SetEnabled(enabled)
    end
    if editBox.EnableMouse then
        editBox:EnableMouse(enabled)
    end

    editBox:SetAlpha(enabled and 1 or 0.45)
end

local function UpdateTokenButtonStates(configFrame)
    if not configFrame or not configFrame.tokenButtons then
        return
    end

    local order, tokenSet = ParseFilterTokens(configFrame.filterInput and configFrame.filterInput:GetText() or "")
    for _, button in ipairs(configFrame.tokenButtons) do
        button:SetSelected(tokenSet[button.token] == true)
    end

    if configFrame.selectedFiltersText then
        if #order == 0 then
            configFrame.selectedFiltersText:SetText("None")
        else
            local labels = {}
            for _, token in ipairs(order) do
                local item = TOKEN_META[token]
                labels[#labels + 1] = item and item.label or token
            end
            configFrame.selectedFiltersText:SetText(table.concat(labels, "  •  "))
        end
    end
end

local function SetFilterInputValue(configFrame, value)
    if not configFrame or not configFrame.filterInput then
        return
    end

    configFrame.filterInput:SetText(value or "")
    UpdateTokenButtonStates(configFrame)
end

local function ApplyAuraFilter(configFrame, value)
    value = NormalizeFilterValue(value)
    addon.db.auraFilter = value
    SetFilterInputValue(configFrame, value)
    if addon.UpdateTrackedAuras then
        addon:UpdateTrackedAuras("settings-filter")
    end
end

local function ToggleFilterToken(configFrame, token)
    local order, set = ParseFilterTokens(configFrame.filterInput and configFrame.filterInput:GetText() or "")
    if set[token] then
        local nextOrder = {}
        for _, current in ipairs(order) do
            if current ~= token then
                nextOrder[#nextOrder + 1] = current
            end
        end
        ApplyAuraFilter(configFrame, table.concat(nextOrder, "|"))
        return
    end

    order[#order + 1] = token
    ApplyAuraFilter(configFrame, NormalizeFilterValue(table.concat(order, "|"), true))
end

local function ApplyCustomBorderColor(configFrame)
    local r = ClampByte(configFrame.redInput and configFrame.redInput:GetText() or 0)
    local g = ClampByte(configFrame.greenInput and configFrame.greenInput:GetText() or 0)
    local b = ClampByte(configFrame.blueInput and configFrame.blueInput:GetText() or 0)

    addon.db.customBorderColor = {
        r = r / 255,
        g = g / 255,
        b = b / 255,
    }
    addon.db.borderMode = "custom"
    addon:RefreshConfigFrame()
    if addon.UpdateTrackedAuras then
        addon:UpdateTrackedAuras("settings-border-color")
    end
end

local function UpdateBorderPreview(configFrame)
    if not configFrame then
        return
    end

    local r, g, b = GetDbBorderColor()
    if configFrame.borderPreview then
        configFrame.borderPreview:SetColorTexture(r, g, b, 1)
    end

    local borderMode = addon and addon.db and addon.db.borderMode or "custom"
    if configFrame.customModeButton then
        configFrame.customModeButton:SetSelected(borderMode ~= "blizzard")
    end
    if configFrame.blizzardModeButton then
        configFrame.blizzardModeButton:SetSelected(borderMode == "blizzard")
    end

    local useCustom = borderMode ~= "blizzard"
    SetEditBoxEnabled(configFrame.redInput, useCustom)
    SetEditBoxEnabled(configFrame.greenInput, useCustom)
    SetEditBoxEnabled(configFrame.blueInput, useCustom)

    if configFrame.colorApplyButton then
        configFrame.colorApplyButton:SetSelected(false)
        configFrame.colorApplyButton:SetAlpha(useCustom and 1 or 0.45)
    end
end

function addon:RefreshConfigFrame()
    local frame = addon.ConfigFrame
    if not frame or not addon.db then
        return
    end

    SetFilterInputValue(frame, GetDbAuraFilter())

    local r, g, b = GetDbBorderColor()
    if frame.redInput then frame.redInput:SetText(tostring(ClampByte(r * 255))) end
    if frame.greenInput then frame.greenInput:SetText(tostring(ClampByte(g * 255))) end
    if frame.blueInput then frame.blueInput:SetText(tostring(ClampByte(b * 255))) end

    UpdateBorderPreview(frame)
end

function addon:OpenConfig()
    if not addon.ConfigFrame then
        addon.ConfigFrame = addon:CreateConfigFrame()
    end

    addon:RefreshConfigFrame()
    addon.ConfigFrame:Show()
end

function addon:CreateConfigFrame()
    local frame = CreateFrame("Frame", "DebuffTrackConfigFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.05, 0.97)
    frame:SetBackdropBorderColor(0.36, 0.36, 0.38, 1)

    tinsert(UISpecialFrames, "DebuffTrackConfigFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("|cff00ccffDebuff Tracker|r Settings")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", 18, -38)
    subtitle:SetText("Configure aura filter tokens for the tracker scan.")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local resetPositionButton = CreateFlatButton(frame, 136, 22, "Reset Position")
    resetPositionButton:SetPoint("TOPRIGHT", -42, -34)
    resetPositionButton:SetScript("OnClick", function()
        if addon and addon.ResetTrackerPosition then
            addon:ResetTrackerPosition()
        end
    end)

    local resetDefaultsButton = CreateFlatButton(frame, 156, 22, "Reset To Defaults")
    resetDefaultsButton:SetPoint("RIGHT", resetPositionButton, "LEFT", -8, 0)
    resetDefaultsButton:SetScript("OnClick", function()
        if addon and addon.ResetConfigDefaults then
            addon:ResetConfigDefaults()
        end
    end)

    local scrollFrame = CreateScrollableFrame(frame)
    scrollFrame:SetPoint("TOPLEFT", 18, -74)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 16)
    frame.rightScroll = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(CONTENT_WIDTH)
    content:SetHeight(1)
    scrollFrame:SetScrollChild(content)
    frame.rightContent = content
    frame.rightTitle = title
    frame.rightTitle = title

    local filterSection = CreateSection(
        content,
        0,
        504,
        nil,
        nil
    )

    local filterInput = CreateFrame("EditBox", nil, filterSection, "InputBoxTemplate")
    filterInput:SetSize(360, 28)
    filterInput:SetPoint("TOPLEFT", 16, filterSection.contentTop)
    filterInput:SetAutoFocus(false)
    filterInput:Hide()
    frame.filterInput = filterInput

    filterInput:SetScript("OnTextChanged", function()
        UpdateTokenButtonStates(frame)
    end)

    local tokenHint = CreateWrappedText(
        filterSection,
        "Click tokens to toggle them. Changes apply immediately.",
        CONTENT_WIDTH - 32,
        "GameFontDisableSmall"
    )
    tokenHint:SetPoint("TOPLEFT", 16, filterSection.contentTop)

    local selectedFiltersLabel = filterSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectedFiltersLabel:SetPoint("TOPLEFT", 16, filterSection.contentTop - 24)
    selectedFiltersLabel:SetText("Selected Filters")

    local selectedFiltersText = CreateWrappedText(filterSection, "None", CONTENT_WIDTH - 32, "GameFontHighlightSmall")
    selectedFiltersText:SetPoint("TOPLEFT", 16, filterSection.contentTop - 44)
    frame.selectedFiltersText = selectedFiltersText

    frame.tokenButtons = {}
    local gridTop = filterSection.contentTop - 92
    local gridColumns = 4
    local buttonWidth = 164
    local buttonHeight = 26
    local xGap = 8
    local yGap = 12
    local tokenRows = math.ceil(#FILTER_TOKENS / gridColumns)

    for index, item in ipairs(FILTER_TOKENS) do
        local row = math.floor((index - 1) / gridColumns)
        local column = (index - 1) % gridColumns
        local button = CreateFlatButton(filterSection, buttonWidth, buttonHeight, item.label)
        button:SetPoint("TOPLEFT", 16 + column * (buttonWidth + xGap), gridTop - row * (buttonHeight + yGap))
        button.token = item.token
        button.tooltipTitle = item.label
        button.tooltipText = item.summary
        button:SetScript("OnClick", function()
            ToggleFilterToken(frame, item.token)
        end)
        frame.tokenButtons[#frame.tokenButtons + 1] = button
    end

    local sectionHeight = math.abs(gridTop - tokenRows * (buttonHeight + yGap)) + 64
    if sectionHeight < 340 then
        sectionHeight = 340
    end

    filterSection:SetHeight(sectionHeight)
    content:SetHeight(sectionHeight + 24)
    return frame
end
