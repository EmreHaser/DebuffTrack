local addonName, addon = ...

local FRAME_WIDTH = 780
local FRAME_HEIGHT = 620
local CONTENT_WIDTH = FRAME_WIDTH - 56
local DEFAULT_AURA_FILTER = "HARMFUL"

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

    local titleOffset = -14
    if titleText and titleText ~= "" then
        local title = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 16, -14)
        title:SetText(titleText)
        titleOffset = -36
    end

    if descriptionText and descriptionText ~= "" then
        local description = CreateWrappedText(section, descriptionText, CONTENT_WIDTH - 32, "GameFontHighlightSmall")
        description:SetPoint("TOPLEFT", 16, titleOffset)
        section.contentTop = titleOffset - 18 - (description.GetStringHeight and description:GetStringHeight() or 0)
    else
        section.contentTop = titleOffset - 6
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

    local borderTop = button:CreateTexture(nil, "BORDER")
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(1)

    local borderBottom = button:CreateTexture(nil, "BORDER")
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(1)

    local borderLeft = button:CreateTexture(nil, "BORDER")
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(1)

    local borderRight = button:CreateTexture(nil, "BORDER")
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(1)

    button.border = {
        SetColorTexture = function(_, r, g, b, a)
            borderTop:SetColorTexture(r, g, b, a)
            borderBottom:SetColorTexture(r, g, b, a)
            borderLeft:SetColorTexture(r, g, b, a)
            borderRight:SetColorTexture(r, g, b, a)
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
            if GameTooltip.AddLine then
                if self.tooltipTitle then
                    GameTooltip:AddLine(self.tooltipTitle, 1, 0.82, 0.15)
                end
                if self.tooltipText then
                    GameTooltip:AddLine(self.tooltipText, 0.92, 0.92, 0.92, true)
                end
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

local function CreateCheckboxRow(parent, width, labelText, descriptionText)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, 46)

    local boxBg = button:CreateTexture(nil, "BACKGROUND")
    boxBg:SetPoint("TOPLEFT", 0, -2)
    boxBg:SetSize(18, 18)
    boxBg:SetColorTexture(0.05, 0.06, 0.08, 0.95)

    local boxTop = button:CreateTexture(nil, "BORDER")
    boxTop:SetPoint("TOPLEFT", boxBg, "TOPLEFT")
    boxTop:SetPoint("TOPRIGHT", boxBg, "TOPRIGHT")
    boxTop:SetHeight(1)

    local boxBottom = button:CreateTexture(nil, "BORDER")
    boxBottom:SetPoint("BOTTOMLEFT", boxBg, "BOTTOMLEFT")
    boxBottom:SetPoint("BOTTOMRIGHT", boxBg, "BOTTOMRIGHT")
    boxBottom:SetHeight(1)

    local boxLeft = button:CreateTexture(nil, "BORDER")
    boxLeft:SetPoint("TOPLEFT", boxBg, "TOPLEFT")
    boxLeft:SetPoint("BOTTOMLEFT", boxBg, "BOTTOMLEFT")
    boxLeft:SetWidth(1)

    local boxRight = button:CreateTexture(nil, "BORDER")
    boxRight:SetPoint("TOPRIGHT", boxBg, "TOPRIGHT")
    boxRight:SetPoint("BOTTOMRIGHT", boxBg, "BOTTOMRIGHT")
    boxRight:SetWidth(1)

    local check = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    check:SetPoint("CENTER", boxBg, "CENTER", 0, 0)
    check:SetText("")

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 28, -1)
    label:SetText(labelText)

    local description = CreateWrappedText(button, descriptionText or "", width - 28, "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", 28, -18)

    function button:SetChecked(checked)
        self.checked = checked == true
        check:SetText(self.checked and "X" or "")
        local borderColor = self.checked and { 0.95, 0.78, 0.22, 1 } or { 0.20, 0.24, 0.30, 1 }
        boxTop:SetColorTexture(unpack(borderColor))
        boxBottom:SetColorTexture(unpack(borderColor))
        boxLeft:SetColorTexture(unpack(borderColor))
        boxRight:SetColorTexture(unpack(borderColor))
        label:SetTextColor(self.checked and 1.0 or 0.9, self.checked and 0.88 or 0.9, self.checked and 0.35 or 0.9)
    end

    function button:GetChecked()
        return self.checked == true
    end

    button:SetScript("OnClick", function(self)
        self:SetChecked(not self:GetChecked())
        if self.OnValueChanged then
            self.OnValueChanged(self:GetChecked())
        end
    end)

    button:SetChecked(false)
    button.label = label
    button.description = description
    return button
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

local function GetDbAuraFilter(filterKey)
    local filter = addon and addon.db and addon.db[filterKey] or nil
    if type(filter) == "string" then
        filter = strtrim(filter)
    end
    if filter and filter ~= "" then
        return filter
    end
    return DEFAULT_AURA_FILTER
end

local function UpdateTokenButtonStates(panel)
    if not panel or not panel.tokenButtons then
        return
    end

    local order, tokenSet = ParseFilterTokens(panel.filterInput and panel.filterInput:GetText() or "")
    for _, button in ipairs(panel.tokenButtons) do
        button:SetSelected(tokenSet[button.token] == true)
    end

    if panel.selectedFiltersText then
        if #order == 0 then
            panel.selectedFiltersText:SetText("None")
        else
            local labels = {}
            for _, token in ipairs(order) do
                local item = TOKEN_META[token]
                labels[#labels + 1] = item and item.label or token
            end
            panel.selectedFiltersText:SetText(table.concat(labels, "  |  "))
        end
    end
end

local function SetFilterInputValue(panel, value)
    if not panel or not panel.filterInput then
        return
    end
    panel.filterInput:SetText(value or "")
    UpdateTokenButtonStates(panel)
end

local function ApplyAuraFilter(panel, value)
    if not panel or not panel.filterKey then
        return
    end

    value = NormalizeFilterValue(value)
    addon.db[panel.filterKey] = value
    SetFilterInputValue(panel, value)
    if addon.UpdateTrackedAuras then
        addon:UpdateTrackedAuras("settings-filter")
    end
end

local function ToggleFilterToken(panel, token)
    local order, set = ParseFilterTokens(panel.filterInput and panel.filterInput:GetText() or "")
    if set[token] then
        local nextOrder = {}
        for _, current in ipairs(order) do
            if current ~= token then
                nextOrder[#nextOrder + 1] = current
            end
        end
        ApplyAuraFilter(panel, table.concat(nextOrder, "|"))
        return
    end

    order[#order + 1] = token
    ApplyAuraFilter(panel, NormalizeFilterValue(table.concat(order, "|"), true))
end

local function CreateFilterPanel(parent, filterKey, titleText, descriptionText)
    local panel = CreateSection(parent, 0, 504, titleText, descriptionText)
    panel.filterKey = filterKey

    local filterInput = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    filterInput:SetSize(360, 28)
    filterInput:SetPoint("TOPLEFT", 16, panel.contentTop)
    filterInput:SetAutoFocus(false)
    filterInput:Hide()
    panel.filterInput = filterInput

    filterInput:SetScript("OnTextChanged", function()
        UpdateTokenButtonStates(panel)
    end)

    local selectedFiltersLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectedFiltersLabel:SetPoint("TOPLEFT", 16, panel.contentTop)
    selectedFiltersLabel:SetText("Selected Filters")

    local selectedFiltersText = CreateWrappedText(panel, "None", CONTENT_WIDTH - 32, "GameFontHighlightSmall")
    selectedFiltersText:SetPoint("TOPLEFT", 16, panel.contentTop - 20)
    panel.selectedFiltersText = selectedFiltersText

    panel.tokenButtons = {}
    local gridTop = panel.contentTop - 68
    local gridColumns = 4
    local buttonWidth = 164
    local buttonHeight = 26
    local xGap = 8
    local yGap = 12

    for index, item in ipairs(FILTER_TOKENS) do
        local row = math.floor((index - 1) / gridColumns)
        local column = (index - 1) % gridColumns
        local button = CreateFlatButton(panel, buttonWidth, buttonHeight, item.label)
        button:SetPoint("TOPLEFT", 16 + column * (buttonWidth + xGap), gridTop - row * (buttonHeight + yGap))
        button.token = item.token
        button.tooltipTitle = item.label
        button.tooltipText = item.summary
        button:SetScript("OnClick", function()
            ToggleFilterToken(panel, item.token)
        end)
        panel.tokenButtons[#panel.tokenButtons + 1] = button
    end

    return panel
end

local function SelectConfigTab(frame, tabKey)
    if not frame or not frame.tabs then
        return
    end

    frame.selectedTab = tabKey
    if frame.tabs.tracker then
        if tabKey == "tracker" then
            frame.tabs.tracker:Show()
        else
            frame.tabs.tracker:Hide()
        end
    end
    if frame.tabs.cotank then
        if tabKey == "cotank" then
            frame.tabs.cotank:Show()
        else
            frame.tabs.cotank:Hide()
        end
    end

    if frame.tabButtons then
        if frame.tabButtons.tracker then
            frame.tabButtons.tracker:SetSelected(tabKey == "tracker")
        end
        if frame.tabButtons.cotank then
            frame.tabButtons.cotank:SetSelected(tabKey == "cotank")
        end
    end
end

function addon:RefreshConfigFrame()
    local frame = addon.ConfigFrame
    if not frame or not addon.db then
        return
    end

    if frame.trackerFilterPanel then
        SetFilterInputValue(frame.trackerFilterPanel, GetDbAuraFilter("auraFilter"))
    end
    if frame.coTankFilterPanel then
        SetFilterInputValue(frame.coTankFilterPanel, GetDbAuraFilter("coTankAuraFilter"))
    end
    if frame.coTankEnabledToggle then
        frame.coTankEnabledToggle:SetChecked(addon.db.coTankEnabled ~= false)
    end
    if frame.coTankShowPlayerToggle then
        frame.coTankShowPlayerToggle:SetChecked(addon.db.coTankShowPlayer == true)
    end

    SelectConfigTab(frame, frame.selectedTab or "tracker")
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
    subtitle:SetText("Manage tracker and co-tank visibility, filters, and Edit Mode behavior.")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local resetMainPositionButton = CreateFlatButton(frame, 136, 22, "Reset Tracker")
    resetMainPositionButton:SetPoint("TOPRIGHT", -42, -34)
    resetMainPositionButton:SetScript("OnClick", function()
        if addon and addon.ResetTrackerPosition then
            addon:ResetTrackerPosition()
        end
    end)

    local resetDefaultsButton = CreateFlatButton(frame, 156, 22, "Reset To Defaults")
    resetDefaultsButton:SetPoint("RIGHT", resetMainPositionButton, "LEFT", -8, 0)
    resetDefaultsButton:SetScript("OnClick", function()
        if addon and addon.ResetConfigDefaults then
            addon:ResetConfigDefaults()
        end
    end)

    local tabTracker = CreateFlatButton(frame, 120, 24, "Tracker")
    tabTracker:SetPoint("TOPLEFT", 18, -66)

    local tabCoTank = CreateFlatButton(frame, 120, 24, "Co-Tank")
    tabCoTank:SetPoint("LEFT", tabTracker, "RIGHT", 8, 0)

    frame.tabButtons = {
        tracker = tabTracker,
        cotank = tabCoTank,
    }

    local scrollFrame = CreateScrollableFrame(frame)
    scrollFrame:SetPoint("TOPLEFT", 18, -98)
    scrollFrame:SetPoint("BOTTOMRIGHT", -28, 16)
    frame.scrollFrame = scrollFrame

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(CONTENT_WIDTH)
    content:SetHeight(620)
    scrollFrame:SetScrollChild(content)
    frame.content = content

    frame.tabs = {}

    local trackerTab = CreateFrame("Frame", nil, content)
    trackerTab:SetPoint("TOPLEFT", 0, 0)
    trackerTab:SetSize(CONTENT_WIDTH, 540)
    frame.tabs.tracker = trackerTab

    local trackerFilterPanel = CreateFilterPanel(
        trackerTab,
        "auraFilter",
        "Tracker Filter",
        "These tokens control which auras the main player tracker will show."
    )
    trackerFilterPanel:SetPoint("TOPLEFT", 0, 0)
    frame.trackerFilterPanel = trackerFilterPanel

    local trackerHint = CreateWrappedText(
        trackerTab,
        "Use Blizzard Edit Mode to move the main tracker and its layout button to change the player tracker icon styling.",
        CONTENT_WIDTH - 8,
        "GameFontDisableSmall"
    )
    trackerHint:SetPoint("TOPLEFT", 4, -520)

    local coTankTab = CreateFrame("Frame", nil, content)
    coTankTab:SetPoint("TOPLEFT", 0, 0)
    coTankTab:SetSize(CONTENT_WIDTH, 620)
    frame.tabs.cotank = coTankTab

    local optionsSection = CreateSection(
        coTankTab,
        0,
        214,
        "Co-Tank Display",
        "Use these settings to show or hide the co-tank block, include your own tank unit, and reset the co-tank Edit Mode position."
    )

    local coTankEnabledToggle = CreateCheckboxRow(
        optionsSection,
        CONTENT_WIDTH - 32,
        "Show Co-Tank Frames",
        "Displays the co-tank block when raid tanks are found."
    )
    coTankEnabledToggle:SetPoint("TOPLEFT", 16, optionsSection.contentTop)
    coTankEnabledToggle.OnValueChanged = function(checked)
        addon.db.coTankEnabled = checked == true
        if addon.UpdateTrackedAuras then
            addon:UpdateTrackedAuras("settings-cotank-enabled")
        end
    end
    frame.coTankEnabledToggle = coTankEnabledToggle

    local coTankShowPlayerToggle = CreateCheckboxRow(
        optionsSection,
        CONTENT_WIDTH - 32,
        "Include My Tank Unit",
        "When enabled, your own raid tank unit is also listed in the co-tank block."
    )
    coTankShowPlayerToggle:SetPoint("TOPLEFT", 16, optionsSection.contentTop - 56)
    coTankShowPlayerToggle.OnValueChanged = function(checked)
        addon.db.coTankShowPlayer = checked == true
        if addon.UpdateTrackedAuras then
            addon:UpdateTrackedAuras("settings-cotank-self")
        end
    end
    frame.coTankShowPlayerToggle = coTankShowPlayerToggle

    local resetCoTankPositionButton = CreateFlatButton(optionsSection, 180, 24, "Reset Co-Tank Position")
    resetCoTankPositionButton:SetPoint("TOPLEFT", 16, optionsSection.contentTop - 128)
    resetCoTankPositionButton:SetScript("OnClick", function()
        if addon and addon.ResetCoTankPosition then
            addon:ResetCoTankPosition()
        end
    end)

    local editModeHint = CreateWrappedText(
        optionsSection,
        "Open Blizzard Edit Mode to move the co-tank anchor separately and use its Layout button for co-tank appearance settings.",
        CONTENT_WIDTH - 220,
        "GameFontDisableSmall"
    )
    editModeHint:SetPoint("LEFT", resetCoTankPositionButton, "RIGHT", 12, 0)

    local coTankFilterPanel = CreateFilterPanel(
        coTankTab,
        "coTankAuraFilter",
        "Co-Tank Filter",
        "These tokens control which auras appear on co-tank frames. This is separate from the main tracker filter."
    )
    coTankFilterPanel:SetPoint("TOPLEFT", 0, -230)
    frame.coTankFilterPanel = coTankFilterPanel

    tabTracker:SetScript("OnClick", function()
        SelectConfigTab(frame, "tracker")
    end)
    tabCoTank:SetScript("OnClick", function()
        SelectConfigTab(frame, "cotank")
    end)

    frame.selectedTab = "tracker"
    SelectConfigTab(frame, "tracker")
    return frame
end
