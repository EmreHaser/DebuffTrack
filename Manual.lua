local addonName, addon = ...

local RIGHT_CONTENT_WIDTH = 660 - 200 - 40  -- must match Config.lua

------------------------------------------------------------
-- Manual spell entry panel (shown inside Config right panel)
------------------------------------------------------------
function addon:ShowManualPanel(configFrame)
    if not configFrame then
        if addon.ConfigFrame then
            configFrame = addon.ConfigFrame
        elseif addon.CreateConfigFrame then
            addon.ConfigFrame = addon:CreateConfigFrame()
            configFrame = addon.ConfigFrame
        end
    end

    if not configFrame or not configFrame.rightScroll or not configFrame.rightTitle then
        return
    end

    -- Replace the right-panel scroll child with a fresh frame
    if configFrame.rightContent then
        configFrame.rightContent:Hide()
    end
    local content = CreateFrame("Frame", nil, configFrame.rightScroll)
    content:SetWidth(RIGHT_CONTENT_WIDTH)
    content:SetHeight(1)
    configFrame.rightScroll:SetScrollChild(content)
    configFrame.rightContent = content

    configFrame.rightTitle:SetText("Manual Spells")

    local yOffset = -8

    -- Input row: label + editbox + add button
    local inputRow = CreateFrame("Frame", nil, content)
    inputRow:SetSize(RIGHT_CONTENT_WIDTH - 10, 30)
    inputRow:SetPoint("TOPLEFT", 6, yOffset)

    local label = inputRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 0, 0)
    label:SetText("Spell ID:")

    local editBox = CreateFrame("EditBox", nil, inputRow, "InputBoxTemplate")
    editBox:SetSize(130, 26)
    editBox:SetPoint("LEFT", label, "RIGHT", 10, 0)
    editBox:SetAutoFocus(false)
    editBox:SetNumeric(true)

    local addBtn = CreateFrame("Button", nil, inputRow, "UIPanelButtonTemplate")
    addBtn:SetSize(70, 26)
    addBtn:SetPoint("LEFT", editBox, "RIGHT", 8, 0)
    addBtn:SetText("Add")

    addBtn:SetScript("OnClick", function()
        local id = tonumber(editBox:GetText())
        if id and id > 0 then
            addon.db.manualSpells[id] = true
            editBox:SetText("")
            -- Refresh the panel to show the new entry
            addon:ShowManualPanel(configFrame)
            if addon.UpdateTrackedAuras then
                addon:UpdateTrackedAuras()
            end
        else
            print("|cff00ccffDebuff Tracker|r: Please enter a valid Spell ID.")
        end
    end)

    -- Allow pressing Enter to add
    editBox:SetScript("OnEnterPressed", function()
        addBtn:Click()
    end)

    yOffset = yOffset - 40

    -- Separator line
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetSize(RIGHT_CONTENT_WIDTH - 20, 1)
    sep:SetPoint("TOPLEFT", 6, yOffset)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.8)
    yOffset = yOffset - 14

    -- List manually added spells
    local hasAny = false
    for spellId, _ in pairs(addon.db.manualSpells) do
        hasAny = true

        local row = CreateFrame("Frame", nil, content)
        row:SetSize(RIGHT_CONTENT_WIDTH - 10, 30)
        row:SetPoint("TOPLEFT", 6, yOffset)

        -- Spell icon
        local iconId = 134400
        local displayName = "Unknown Spell"
        local spellInfo = C_Spell.GetSpellInfo(spellId)
        if spellInfo then
            iconId = spellInfo.iconID or iconId
            displayName = spellInfo.name or displayName
        end

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(24, 24)
        icon:SetPoint("LEFT", 0, 0)
        icon:SetTexture(iconId)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- Name label
        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        nameText:SetText(displayName .. "  |cff888888(ID: " .. spellId .. ")|r")

        -- Remove button
        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetSize(60, 22)
        removeBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        removeBtn:SetText("Remove")
        removeBtn:SetScript("OnClick", function()
            addon.db.manualSpells[spellId] = nil
            addon:ShowManualPanel(configFrame)
            if addon.UpdateTrackedAuras then
                addon:UpdateTrackedAuras()
            end
        end)

        yOffset = yOffset - 32
    end

    if not hasAny then
        local noData = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        noData:SetPoint("TOPLEFT", 10, yOffset)
        noData:SetText("No manual spells added yet.")
        yOffset = yOffset - 20
    end

    content:SetHeight(math.abs(yOffset) + 10)
end
