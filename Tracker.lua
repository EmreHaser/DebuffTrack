local addonName, addon = ...

local trackerFrame = nil
local tickFrame = nil
local scanTooltip = nil
local layoutEditorFrame = nil
local buttons = {}
local watchButtons = {}
local trackerEventFrame = CreateFrame("Frame")
local auraDispelColorCurve = nil

local MAX_ICONS = 10
local ICON_SIZE = 36
local ICON_SPACING = 4
local ANCHOR_ICON_COUNT = 4
local TRACKER_NORMAL_STRATA = "TOOLTIP"
local TRACKER_EDITOR_STRATA = "MEDIUM"
local EDIT_PREVIEW_ICONS = { 132345, 136033, 463281 }
local WATCH_ROW_GAP = 10
local AURA_MIN_DISPLAY_COUNT = 2
local AURA_MAX_DISPLAY_COUNT = 99
local DEFAULT_AURA_FILTER = "IMPORTANT"
local HIDDEN_MONK_AURAS = {
    [124273] = true, -- Heavy Stagger
    [124274] = true, -- Moderate Stagger
    [124275] = true, -- Light Stagger
}

local apiMethodUsed = nil
local filterMethodUsed = nil
local lastAuraCount = 0
local lastUpdateTime = 0
local lastUpdateReason = "init"
local activeButtonCount = 0
local lastDebugSnapshot = nil
local lastCombatSnapshot = nil
local combatStateActive = false
local playerGUID = nil
local auraCache = {
    byKey = {},
    order = {},
}
local auraInfo = {}
local auraFiltered = {
    HARMFUL = {},
}
local auraOrder = {}
local eventCounters = {
    unitAura = 0,
    enterCombat = 0,
    leaveCombat = 0,
    combatPoll = 0,
}

local function IsInCombat()
    return InCombatLockdown and InCombatLockdown() or false
end

local function IsPlayerMonk()
    if UnitClassBase then
        local classTag = UnitClassBase("player")
        return classTag == "MONK"
    end

    if UnitClass then
        local _, classTag = UnitClass("player")
        return classTag == "MONK"
    end

    return false
end

local GetAuraByIndex
local ScanAllPlayerDebuffs

local function IsSecretValue(value)
    return issecretvalue and issecretvalue(value) or false
end

local function NotSecretValue(value)
    return not IsSecretValue(value)
end

local function CanAccessValue(value)
    if canaccessvalue then
        local ok, accessible = pcall(canaccessvalue, value)
        if ok then
            return accessible
        end
    end

    return not IsSecretValue(value)
end

local function GetAccessibleAuraValue(value)
    if value == nil then
        return nil
    end

    if not CanAccessValue(value) then
        return nil
    end

    return value
end

local function SetAuraQueryFilter(aura, auraFilter)
    if aura and auraFilter then
        aura.queryFilter = auraFilter
    end

    return aura
end

local function GetConfiguredAuraFilter()
    local configuredFilter = addon and addon.db and addon.db.auraFilter or nil
    if type(configuredFilter) == "string" then
        configuredFilter = strtrim(configuredFilter)
    end

    if configuredFilter and configuredFilter ~= "" then
        return configuredFilter
    end

    return DEFAULT_AURA_FILTER
end

local function CanUseAuraIndexFilter(auraFilter)
    if type(auraFilter) ~= "string" or auraFilter == "" then
        return false
    end

    return string.find(auraFilter, "HARMFUL", 1, true) ~= nil
        or string.find(auraFilter, "HELPFUL", 1, true) ~= nil
end

local function GetConfiguredCustomBorderColor()
    local color = addon and addon.db and addon.db.customBorderColor or nil
    if type(color) ~= "table" then
        return 0, 0, 0
    end

    local function NormalizeComponent(value)
        value = tonumber(value) or 0
        if value < 0 then
            return 0
        end
        if value > 1 then
            return 1
        end
        return value
    end

    return NormalizeComponent(color.r), NormalizeComponent(color.g), NormalizeComponent(color.b)
end

local function EnsureAuraDispelColorCurve()
    if auraDispelColorCurve then
        return auraDispelColorCurve
    end

    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve or not CreateColor then
        return nil
    end

    local curve = C_CurveUtil.CreateColorCurve()
    if not curve then
        return nil
    end

    if curve.SetType and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
        curve:SetType(Enum.LuaCurveType.Step)
    end

    local function AddColorPoint(x, colorKey, fallbackR, fallbackG, fallbackB)
        local color = DEBUFF_TYPE_COLORS and DEBUFF_TYPE_COLORS[colorKey] or nil
        local r = color and color.r or fallbackR
        local g = color and color.g or fallbackG
        local b = color and color.b or fallbackB
        curve:AddPoint(x, CreateColor(r, g, b, 1))
    end

    AddColorPoint(0, "none", 1.0, 0.0, 0.0)
    AddColorPoint(1, "Magic", 0.20, 0.60, 1.00)
    AddColorPoint(2, "Curse", 0.60, 0.00, 1.00)
    AddColorPoint(3, "Disease", 0.80, 0.60, 0.00)
    AddColorPoint(4, "Poison", 0.00, 0.60, 0.00)
    AddColorPoint(9, "none", 1.0, 0.0, 0.0)

    auraDispelColorCurve = curve
    return auraDispelColorCurve
end

local function GetDefaultLayoutSettings()
    return {
        iconWidth = ICON_SIZE,
        iconHeight = ICON_SIZE,
        borderThickness = 2,
        countOffsetX = 12,
        countOffsetY = -10,
        countFontSize = 18,
        durationOffsetX = 0,
        durationOffsetY = -26,
        durationFontSize = 16,
    }
end

local function CloneLayoutSettings(layout)
    local defaults = GetDefaultLayoutSettings()
    layout = type(layout) == "table" and layout or {}
    local legacyScale = tonumber(layout.scale) or 1

    return {
        iconWidth = tonumber(layout.iconWidth) or math.floor((defaults.iconWidth * legacyScale) + 0.5),
        iconHeight = tonumber(layout.iconHeight) or math.floor((defaults.iconHeight * legacyScale) + 0.5),
        borderThickness = tonumber(layout.borderThickness) or defaults.borderThickness,
        countOffsetX = tonumber(layout.countOffsetX) or defaults.countOffsetX,
        countOffsetY = tonumber(layout.countOffsetY) or defaults.countOffsetY,
        countFontSize = tonumber(layout.countFontSize) or defaults.countFontSize,
        durationOffsetX = tonumber(layout.durationOffsetX) or defaults.durationOffsetX,
        durationOffsetY = tonumber(layout.durationOffsetY) or defaults.durationOffsetY,
        durationFontSize = tonumber(layout.durationFontSize) or defaults.durationFontSize,
    }
end

local function GetConfiguredLayoutSettings()
    if not addon or not addon.db then
        return GetDefaultLayoutSettings()
    end

    addon.db.layout = CloneLayoutSettings(addon.db.layout)
    return addon.db.layout
end

local function ClampIconDimension(value)
    value = tonumber(value) or ICON_SIZE
    if value < 20 then
        return 20
    end
    if value > 120 then
        return 120
    end
    return math.floor(value + 0.5)
end

local function ClampFontSize(value)
    value = tonumber(value) or 14
    if value < 8 then
        return 8
    end
    if value > 48 then
        return 48
    end
    return math.floor(value + 0.5)
end

local function ClampBorderThickness(value)
    value = tonumber(value) or 2
    if value < 1 then
        return 1
    end
    if value > 12 then
        return 12
    end
    return math.floor(value + 0.5)
end

local function ClampColorComponentFromInput(value)
    value = tonumber(value) or 0
    if value < 0 then
        value = 0
    elseif value > 255 then
        value = 255
    end
    return value / 255
end

local function GetTextFontPath()
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function GetLayoutMetrics(layout)
    layout = layout or GetConfiguredLayoutSettings()

    local iconWidth = ClampIconDimension(layout.iconWidth)
    local iconHeight = ClampIconDimension(layout.iconHeight)
    local borderThickness = ClampBorderThickness(layout.borderThickness)
    local durationBandHeight = math.max(18, ClampFontSize(layout.durationFontSize) + 4)
    local mainRowHeight = iconHeight + durationBandHeight
    local watchRowOffset = mainRowHeight + WATCH_ROW_GAP
    local trackerHeight = mainRowHeight + WATCH_ROW_GAP + iconHeight

    return {
        iconWidth = iconWidth,
        iconHeight = iconHeight,
        borderThickness = borderThickness,
        totalWidth = (MAX_ICONS * iconWidth) + ((MAX_ICONS - 1) * ICON_SPACING),
        mainRowHeight = mainRowHeight,
        watchRowOffset = watchRowOffset,
        trackerHeight = trackerHeight,
        anchorWidth = math.max((ANCHOR_ICON_COUNT * iconWidth) + ((ANCHOR_ICON_COUNT - 1) * ICON_SPACING), 240),
        anchorHeight = math.max(iconHeight, 44),
    }
end

local function SafeTrackedLookup(source, value)
    if not source or value == nil then
        return false
    end

    local accessibleValue = GetAccessibleAuraValue(value)
    if accessibleValue ~= nil then
        return source[accessibleValue] == true
    end

    local ok, matched = pcall(function()
        return source[value] == true
    end)

    return ok and matched or false
end

local function GetCanonicalSpellName(spellId)
    if not spellId or not C_Spell or not C_Spell.GetSpellInfo then
        return nil
    end

    local ok, spellInfo = pcall(C_Spell.GetSpellInfo, spellId)
    if ok and type(spellInfo) == "table" then
        return spellInfo.name
    end

    return nil
end

local function IsTrackedAura(trackedLookup, aura, extraSpellId, extraSpellName)
    if not trackedLookup or not trackedLookup.hasAny or not aura then
        return false
    end

    if SafeTrackedLookup(trackedLookup.spellIds, extraSpellId)
        or SafeTrackedLookup(trackedLookup.spellIds, aura.spellId)
    then
        return true
    end

    if SafeTrackedLookup(trackedLookup.spellNames, extraSpellName)
        or SafeTrackedLookup(trackedLookup.spellNames, aura.name)
    then
        return true
    end

    local canonicalName = GetCanonicalSpellName(extraSpellId or aura.spellId)
    if SafeTrackedLookup(trackedLookup.spellNames, canonicalName) then
        return true
    end

    return false
end

local function FormatDiagnosticValue(value)
    if value == nil then
        return "nil"
    end

    if not CanAccessValue(value) then
        return "<secret>"
    end

    return tostring(value)
end

local function FormatAuraDataAsJson(aura)
    if aura == nil then
        return "null"
    end

    return "{"
        .. "\"auraInstanceID\":\"" .. FormatDiagnosticValue(aura.auraInstanceID) .. "\","
        .. "\"spellId\":\"" .. FormatDiagnosticValue(aura.spellId) .. "\","
        .. "\"name\":\"" .. FormatDiagnosticValue(aura.name) .. "\","
        .. "\"icon\":\"" .. FormatDiagnosticValue(aura.icon) .. "\","
        .. "\"duration\":\"" .. FormatDiagnosticValue(aura.duration) .. "\","
        .. "\"expirationTime\":\"" .. FormatDiagnosticValue(aura.expirationTime) .. "\","
        .. "\"applications\":\"" .. FormatDiagnosticValue(aura.applications) .. "\","
        .. "\"dispelName\":\"" .. FormatDiagnosticValue(aura.dispelName) .. "\","
        .. "\"isHarmful\":\"" .. FormatDiagnosticValue(aura.isHarmful) .. "\","
        .. "\"isHelpful\":\"" .. FormatDiagnosticValue(aura.isHelpful) .. "\","
        .. "\"sourceUnit\":\"" .. FormatDiagnosticValue(aura.sourceUnit) .. "\""
        .. "}"
end

local function EnsureScanTooltip()
    if scanTooltip then
        return scanTooltip
    end

    if not CreateFrame then
        return nil
    end

    scanTooltip = CreateFrame("GameTooltip", "DebuffAddonScanTooltip", UIParent, "GameTooltipTemplate")
    if not scanTooltip then
        return nil
    end

    if scanTooltip.SetOwner then
        scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end

    return scanTooltip
end

local function SetTooltipAuraByIndex(tooltip, unit, index, auraFilter)
    if not tooltip or not index then
        return false
    end

    local effectiveFilter = auraFilter or GetConfiguredAuraFilter()

    if tooltip.SetUnitAura then
        tooltip:SetUnitAura(unit, index, effectiveFilter)
        return true
    end

    if tooltip.SetUnitDebuff then
        tooltip:SetUnitDebuff(unit, index, effectiveFilter)
        return true
    end

    return false
end

local function GetTooltipSpellIDByAuraIndex(index, auraFilter)
    local tooltip = EnsureScanTooltip()
    if not tooltip then
        return nil
    end

    if tooltip.ClearLines then
        tooltip:ClearLines()
    end
    if not SetTooltipAuraByIndex(tooltip, "player", index, auraFilter) then
        return nil
    end

    if tooltip.GetTooltipData then
        local ok, data = pcall(tooltip.GetTooltipData, tooltip)
        if ok and type(data) == "table" and data.id ~= nil then
            return data.id
        end
    end

    if tooltip.GetSpell then
        local ok, _, spellId = pcall(tooltip.GetSpell, tooltip)
        if ok then
            return spellId
        end
    end

    return nil
end

local function GetTooltipAuraDebugByAuraIndex(index, auraFilter)
    local tooltip = EnsureScanTooltip()
    if not tooltip then
        return {
            spellId = nil,
            spellName = nil,
            dataId = nil,
        }
    end

    if tooltip.ClearLines then
        tooltip:ClearLines()
    end
    if not SetTooltipAuraByIndex(tooltip, "player", index, auraFilter) then
        return {
            spellId = nil,
            spellName = nil,
            dataId = nil,
        }
    end

    local dataId = nil
    if tooltip.GetTooltipData then
        local ok, data = pcall(tooltip.GetTooltipData, tooltip)
        if ok and type(data) == "table" then
            dataId = data.id
        end
    end

    local spellName = nil
    local spellId = nil
    if tooltip.GetSpell then
        local ok, rawSpellName, rawSpellId = pcall(tooltip.GetSpell, tooltip)
        if ok then
            spellName = rawSpellName
            spellId = rawSpellId
        end
    end

    return {
        spellId = spellId,
        spellName = spellName,
        dataId = dataId,
    }
end

local function IsHiddenMonkAuraSpellId(value)
    if value == nil then
        return false
    end

    local accessibleValue = GetAccessibleAuraValue(value)
    if accessibleValue ~= nil then
        return HIDDEN_MONK_AURAS[accessibleValue] == true
    end

    local ok, matched = pcall(function()
        return HIDDEN_MONK_AURAS[value] == true
    end)

    return ok and matched or false
end

local function ShouldHideRawAura(aura)
    if not aura or not aura.auraIndex or not IsPlayerMonk() then
        return false
    end

    local tooltipDebug = GetTooltipAuraDebugByAuraIndex(aura.auraIndex, aura.queryFilter)
    if IsHiddenMonkAuraSpellId(tooltipDebug and tooltipDebug.spellId) then
        return true
    end

    if IsHiddenMonkAuraSpellId(tooltipDebug and tooltipDebug.dataId) then
        return true
    end

    return false
end

local function ClearTableEntries(tbl)
    for key in pairs(tbl) do
        tbl[key] = nil
    end
end

local function EnsureAuraState(unit)
    if not auraInfo[unit] then
        auraInfo[unit] = {}
    end
    if not auraFiltered.HARMFUL[unit] then
        auraFiltered.HARMFUL[unit] = {}
    end
    if not auraOrder[unit] then
        auraOrder[unit] = {}
    end
end

local function ClearAuraState(unit)
    EnsureAuraState(unit)
    ClearTableEntries(auraInfo[unit])
    ClearTableEntries(auraFiltered.HARMFUL[unit])
    ClearTableEntries(auraOrder[unit])
end

local function AddAuraOrder(unit, auraInstanceID)
    if auraInstanceID == nil then
        return
    end

    EnsureAuraState(unit)
    local order = auraOrder[unit]
    for i = 1, #order do
        if order[i] == auraInstanceID then
            return
        end
    end

    order[#order + 1] = auraInstanceID
end

local function RemoveAuraOrder(unit, auraInstanceID)
    if auraInstanceID == nil or not auraOrder[unit] then
        return
    end

    local order = auraOrder[unit]
    for i = #order, 1, -1 do
        if order[i] == auraInstanceID then
            table.remove(order, i)
            return
        end
    end
end

local function GetAuraCacheKey(aura)
    if not aura then
        return nil
    end

    if aura.auraInstanceID ~= nil then
        return "instance:" .. tostring(aura.auraInstanceID)
    end

    if aura.auraIndex ~= nil then
        return "index:" .. tostring(aura.auraIndex)
    end

    return nil
end

local function UnpackAuraData(data)
    if not data then
        return nil
    end

    local name = data.name
    local icon = data.icon
    local applications = data.applications
    local dispelName = data.dispelName or data.debuffType
    local duration = data.duration
    local expirationTime = data.expirationTime
    local spellId = data.spellId
    local auraInstanceID = data.auraInstanceID

    return name, icon, applications, dispelName, duration, expirationTime, spellId, auraInstanceID
end

local function ResolveFullAuraData(aura)
    if not aura then
        return nil
    end

    if aura.auraInstanceID
        and C_UnitAuras
        and C_UnitAuras.GetAuraDataByAuraInstanceID
        and (aura.spellId == nil or aura.icon == nil or aura.name == nil or aura.duration == nil)
    then
        local fullAura = C_UnitAuras.GetAuraDataByAuraInstanceID("player", aura.auraInstanceID)
        if fullAura then
            return fullAura
        end
    end

    return aura
end

local function NormalizeAura(aura)
    if not aura then
        return nil
    end

    aura = ResolveFullAuraData(aura)

    return {
        name = aura.name,
        icon = aura.icon,
        applications = aura.applications,
        dispelName = aura.dispelName or aura.debuffType,
        duration = aura.duration,
        expirationTime = aura.expirationTime,
        spellId = aura.spellId,
        auraInstanceID = aura.auraInstanceID,
        auraIndex = aura.auraIndex or aura.index,
    }
end

local function ResetAuraCache()
    ClearTableEntries(auraCache.byKey)
    ClearTableEntries(auraCache.order)
end

local function StoreCachedAura(aura)
    local normalized = NormalizeAura(aura)
    local key = GetAuraCacheKey(normalized)
    if not normalized or not key then
        return
    end

    local exists = auraCache.byKey[key] ~= nil
    auraCache.byKey[key] = normalized
    if not exists then
        auraCache.order[#auraCache.order + 1] = key
    end
end

local function RemoveCachedAuraByInstanceID(auraInstanceID)
    if auraInstanceID == nil then
        return
    end

    local key = "instance:" .. tostring(auraInstanceID)
    if auraCache.byKey[key] == nil then
        return
    end

    auraCache.byKey[key] = nil
    for i = #auraCache.order, 1, -1 do
        if auraCache.order[i] == key then
            table.remove(auraCache.order, i)
            break
        end
    end
end

local function RebuildAuraCache()
    ResetAuraCache()

    if C_UnitAuras and C_UnitAuras.GetAuraSlots and C_UnitAuras.GetAuraDataBySlot then
        local continuationToken = nil
        repeat
            local values = { pcall(C_UnitAuras.GetAuraSlots, "player", "HARMFUL", 40, continuationToken) }
            local ok = values[1]
            continuationToken = ok and values[2] or nil
            if not ok then
                break
            end

            for i = 3, #values do
                local slot = values[i]
                local auraOk, aura = pcall(C_UnitAuras.GetAuraDataBySlot, "player", slot)
                if auraOk and aura then
                    StoreCachedAura(aura)
                end
            end
        until not continuationToken
    end

    if #auraCache.order > 0 then
        return
    end

    for i = 1, 40 do
        local aura = GetAuraByIndex(i)
        if not aura then
            break
        end

        StoreCachedAura(aura)
    end
end

local function UpdateAuraCacheFromInfo(updateInfo)
    if not updateInfo or updateInfo.isFullUpdate then
        RebuildAuraCache()
        return
    end

    if updateInfo.addedAuras then
        for _, aura in ipairs(updateInfo.addedAuras) do
            StoreCachedAura(aura)
        end
    end

    if updateInfo.updatedAuraInstanceIDs and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", auraInstanceID)
            if ok and aura then
                StoreCachedAura(aura)
            else
                RemoveCachedAuraByInstanceID(auraInstanceID)
            end
        end
    end

    if updateInfo.removedAuraInstanceIDs then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            RemoveCachedAuraByInstanceID(auraInstanceID)
        end
    end
end

GetAuraByIndex = function(index)
    local auraFilter = GetConfiguredAuraFilter()

    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        apiMethodUsed = apiMethodUsed or "GetDebuffDataByIndex"
        return SetAuraQueryFilter(NormalizeAura(C_UnitAuras.GetDebuffDataByIndex("player", index, auraFilter)), auraFilter)
    end

    if CanUseAuraIndexFilter(auraFilter) and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        apiMethodUsed = apiMethodUsed or "GetAuraDataByIndex"
        return SetAuraQueryFilter(NormalizeAura(C_UnitAuras.GetAuraDataByIndex("player", index, auraFilter)), auraFilter)
    end

    if CanUseAuraIndexFilter(auraFilter) and UnitAura then
        apiMethodUsed = apiMethodUsed or "UnitAura"
        local name, icon, applications, dispelType, duration, expirationTime, _, _, _, spellId = UnitAura("player", index, auraFilter)
        if not name then
            return nil
        end

        return SetAuraQueryFilter({
            name = name,
            icon = icon,
            applications = applications,
            dispelName = dispelType,
            duration = duration,
            expirationTime = expirationTime,
            spellId = spellId,
            auraIndex = index,
        }, auraFilter)
    end

    return nil
end

function addon:IsSpellTracked(spellId)
    if not spellId or not addon.db then
        return false
    end

    local function SafeLookup(source)
        if not source then
            return false
        end

        local ok, value = pcall(function()
            return source[spellId] == true
        end)
        if ok and value then
            return true
        end
        return false
    end

    return SafeLookup(addon.db.trackedSpells)
        or SafeLookup(addon.db.manualSpells)
        or false
end

local function BuildTrackedLookup()
    local lookup = {
        spells = {},
        spellIds = {},
        spellNames = {},
        hasAny = false,
    }
    local seen = {}

    local function AddSpellIds(source)
        if not source then
            return
        end

        for selectedSpellId, enabled in pairs(source) do
            local numericSpellId = tonumber(selectedSpellId)
            if enabled and numericSpellId and not seen[numericSpellId] then
                seen[numericSpellId] = true
                lookup.hasAny = true
                local spellName = nil
                if C_Spell and C_Spell.GetSpellInfo then
                    local spellInfo = C_Spell.GetSpellInfo(numericSpellId)
                    spellName = spellInfo and spellInfo.name or nil
                end
                lookup.spellIds[numericSpellId] = true
                if spellName then
                    lookup.spellNames[spellName] = true
                end
                lookup.spells[#lookup.spells + 1] = {
                    spellId = numericSpellId,
                    spellName = spellName,
                }
            end
        end
    end

    if addon and addon.db then
        AddSpellIds(addon.db.trackedSpells)
        AddSpellIds(addon.db.manualSpells)
    end

    table.sort(lookup.spells, function(a, b)
        return a.spellId < b.spellId
    end)

    return lookup
end

local function GetUnitAuraInstanceOrder(unit, filter, maxCount)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuraInstanceIDs then
        return nil
    end

    local ok, auraInstanceIDs = pcall(C_UnitAuras.GetUnitAuraInstanceIDs, unit, filter, maxCount or 40)
    if ok and type(auraInstanceIDs) == "table" then
        return auraInstanceIDs
    end

    return nil
end

local function GetTrackedAuraInstanceIDBySpellID(unit, spellId)
    if not spellId or not C_UnitAuras or not C_UnitAuras.GetUnitAuraBySpellID then
        return nil
    end

    local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellId)
    if ok and aura and aura.auraInstanceID ~= nil then
        return aura.auraInstanceID
    end

    return nil
end

local function GetTrackedAuraBySpellIDRaw(unit, spellId)
    if not spellId or not C_UnitAuras or not C_UnitAuras.GetUnitAuraBySpellID then
        return nil
    end

    local ok, aura = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellId)
    if ok then
        return aura
    end

    return nil
end

local function DebugGetUnitAuraBySpellIDCall(unit, spellId)
    if not spellId or not C_UnitAuras or not C_UnitAuras.GetUnitAuraBySpellID then
        return {
            ok = false,
            resultType = "missing-api",
            error = "GetUnitAuraBySpellID unavailable",
        }
    end

    local ok, result = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellId)
    return {
        ok = ok,
        resultType = type(result),
        error = ok and nil or result,
    }
end

local function AuraIsHarmful(unit, aura)
    if not aura then
        return false
    end

    if NotSecretValue(aura.isHarmful) and aura.isHarmful ~= nil then
        return aura.isHarmful
    end

    if aura.auraIsHarmful ~= nil then
        return aura.auraIsHarmful
    end

    if C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID and aura.auraInstanceID then
        local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, aura.auraInstanceID, "HARMFUL")
        if ok then
            aura.auraIsHarmful = not filteredOut
            return aura.auraIsHarmful
        end
    end

    return true
end

local function ShouldSkipAuraFilter(aura, filter)
    if not aura then
        return true
    end

    if filter == "HARMFUL" then
        return not AuraIsHarmful("player", aura)
    end

    return true
end

local function StoreAuraState(unit, aura)
    local normalized = NormalizeAura(aura)
    if not normalized or not normalized.auraInstanceID then
        return
    end

    EnsureAuraState(unit)

    if AuraIsHarmful(unit, normalized) then
        normalized.auraIsHarmful = true
    end

    auraInfo[unit][normalized.auraInstanceID] = normalized
    auraFiltered.HARMFUL[unit][normalized.auraInstanceID] =
        not ShouldSkipAuraFilter(normalized, "HARMFUL") and normalized or nil
    AddAuraOrder(unit, normalized.auraInstanceID)
end

local function RemoveAuraState(unit, auraInstanceID)
    if auraInstanceID == nil then
        return
    end

    EnsureAuraState(unit)
    auraInfo[unit][auraInstanceID] = nil
    auraFiltered.HARMFUL[unit][auraInstanceID] = nil
    RemoveAuraOrder(unit, auraInstanceID)
end

local function ProcessExistingHarmfulAuras(unit)
    unit = unit or "player"
    ClearAuraState(unit)

    local rawAuras = ScanAllPlayerDebuffs(40)
    local rawByInstanceID = {}
    for _, aura in ipairs(rawAuras) do
        if aura and aura.auraInstanceID ~= nil then
            rawByInstanceID[aura.auraInstanceID] = aura
        end
    end

    local auraInstanceIDs = GetUnitAuraInstanceOrder(unit, "HARMFUL", 40)
    if auraInstanceIDs and #auraInstanceIDs > 0 then
        for _, auraInstanceID in ipairs(auraInstanceIDs) do
            local aura = rawByInstanceID[auraInstanceID]
            if not aura and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
                if ok and auraData then
                    aura = NormalizeAura(auraData)
                end
            end

            if aura then
                StoreAuraState(unit, aura)
            else
                AddAuraOrder(unit, auraInstanceID)
            end
        end
        return
    end

    for _, aura in ipairs(rawAuras) do
        StoreAuraState(unit, aura)
    end
end

local function UpdateAuraStateFromInfo(unit, updateInfo)
    unit = unit or "player"
    EnsureAuraState(unit)

    if not updateInfo or updateInfo.isFullUpdate or not next(auraInfo[unit]) then
        ProcessExistingHarmfulAuras(unit)
        return
    end

    if updateInfo.addedAuras then
        for _, aura in ipairs(updateInfo.addedAuras) do
            StoreAuraState(unit, aura)
        end
    end

    if updateInfo.updatedAuraInstanceIDs and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
            if ok and aura then
                StoreAuraState(unit, aura)
            else
                RemoveAuraState(unit, auraInstanceID)
            end
        end
    end

    if updateInfo.removedAuraInstanceIDs then
        for _, auraInstanceID in ipairs(updateInfo.removedAuraInstanceIDs) do
            RemoveAuraState(unit, auraInstanceID)
        end
    end
end

local function CollectFilteredAuras(unit, trackedLookup)
    unit = unit or "player"
    EnsureAuraState(unit)

    local result = {}
    local filtered = auraFiltered.HARMFUL[unit]
    local order = auraOrder[unit]
    local rawAuras = ScanAllPlayerDebuffs(40)
    local rawByInstanceID = {}

    for _, aura in ipairs(rawAuras) do
        if aura and aura.auraInstanceID ~= nil then
            rawByInstanceID[aura.auraInstanceID] = aura
        end
    end

    for _, auraInstanceID in ipairs(order) do
        local aura = filtered[auraInstanceID]
        if aura and (not trackedLookup or not trackedLookup.hasAny or IsTrackedAura(trackedLookup, aura)) then
            result[#result + 1] = rawByInstanceID[auraInstanceID] or aura
            if #result >= MAX_ICONS then
                break
            end
        end
    end

    return result
end

local function CollectTrackedAurasByTooltip(unit, trackedLookup)
    unit = unit or "player"

    local result = {}
    local rawAuras = ScanAllPlayerDebuffs(40)

    for _, aura in ipairs(rawAuras) do
        if aura and aura.auraIndex then
            local tooltipDebug = GetTooltipAuraDebugByAuraIndex(aura.auraIndex, aura.queryFilter)
            local matched = SafeTrackedLookup(trackedLookup.spellIds, tooltipDebug and tooltipDebug.spellId)
                or SafeTrackedLookup(trackedLookup.spellIds, tooltipDebug and tooltipDebug.dataId)
                or SafeTrackedLookup(trackedLookup.spellNames, tooltipDebug and tooltipDebug.spellName)

            if matched then
                result[#result + 1] = aura
                if #result >= MAX_ICONS then
                    break
                end
            end
        end
    end

    return result
end

ScanAllPlayerDebuffs = function(maxCount)
    local result = {}
    local auraFilter = GetConfiguredAuraFilter()

    for i = 1, 40 do
        local aura = GetAuraByIndex(i)
        if not aura then
            break
        end
        aura.auraIndex = aura.auraIndex or i
        if not ShouldHideRawAura(aura) then
            result[#result + 1] = aura
            if maxCount and #result >= maxCount then
                break
            end
        end
    end

    if #result > 0 or UnitAura then
        return result
    end

    if AuraUtil and AuraUtil.ForEachAura then
        apiMethodUsed = apiMethodUsed or "AuraUtil.ForEachAura"
        AuraUtil.ForEachAura("player", auraFilter, 40, function(aura)
            local normalized = SetAuraQueryFilter(NormalizeAura(aura), auraFilter)
            if normalized then
                result[#result + 1] = normalized
            end
            return maxCount and #result >= maxCount or false
        end, true)
    end

    return result
end

local function GetFilterAuraByIndex(index)
    local auraFilter = GetConfiguredAuraFilter()

    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        filterMethodUsed = filterMethodUsed or "GetDebuffDataByIndex"
        local data = C_UnitAuras.GetDebuffDataByIndex("player", index, auraFilter)
        if data then
            local name, _, _, _, _, _, spellId, auraInstanceID = UnpackAuraData(data)
            return {
                auraIndex = index,
                auraInstanceID = NotSecretValue(auraInstanceID) and auraInstanceID or nil,
                spellId = NotSecretValue(spellId) and spellId or nil,
                name = NotSecretValue(name) and name or nil,
            }
        end
    end

    if CanUseAuraIndexFilter(auraFilter) and UnitAura then
        filterMethodUsed = filterMethodUsed or "UnitAura"
        local name, _, _, _, _, _, _, _, _, spellId = UnitAura("player", index, auraFilter)
        if name then
            return {
                auraIndex = index,
                spellId = spellId,
                name = name,
            }
        end
    end

    if CanUseAuraIndexFilter(auraFilter) and C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        filterMethodUsed = filterMethodUsed or "GetAuraDataByIndex"
        local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, auraFilter)
        if not ok or not data then
            return nil
        end

        local name, _, _, _, _, _, spellId, auraInstanceID = UnpackAuraData(data)
        return {
            auraIndex = index,
            auraInstanceID = NotSecretValue(auraInstanceID) and auraInstanceID or nil,
            spellId = NotSecretValue(spellId) and spellId or nil,
            name = NotSecretValue(name) and name or nil,
        }
    end

    if CanUseAuraIndexFilter(auraFilter) and UnitAura then
        filterMethodUsed = filterMethodUsed or "UnitAura"
        local name, _, _, _, _, _, _, _, _, spellId = UnitAura("player", index, auraFilter)
        if name then
            return {
                auraIndex = index,
                spellId = spellId,
                name = name,
            }
        end
    end

    return nil
end

local function ScanFilterablePlayerDebuffs()
    local result = {}

    for i = 1, 40 do
        local aura = GetFilterAuraByIndex(i)
        if not aura then
            break
        end

        result[#result + 1] = aura
        if #result >= MAX_ICONS then
            break
        end
    end

    return result
end

local function ScanTrackedPlayerDebuffs(trackedLookup)
    if not trackedLookup or not trackedLookup.hasAny then
        return ScanAllPlayerDebuffs(MAX_ICONS)
    end

    local result = CollectTrackedAurasByTooltip("player", trackedLookup)
    if #result > 0 then
        filterMethodUsed = "GetDebuffDataByIndex+Tooltip.ByIndex"
        return result
    end

    filterMethodUsed = "Tooltip.ByIndex.NoMatch"
    return result
end

local function ScanPlayerDebuffs()
    filterMethodUsed = "Configured.AllDebuffs"
    return ScanAllPlayerDebuffs(MAX_ICONS)
end

local function GetBorderColor(aura)
    if addon and addon.db and addon.db.borderMode == "blizzard" then
        local curve = EnsureAuraDispelColorCurve()
        if aura and aura.auraInstanceID and curve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
            local ok, colorOrR, g, b = pcall(C_UnitAuras.GetAuraDispelTypeColor, "player", aura.auraInstanceID, curve)
            if ok then
                if type(colorOrR) == "table" then
                    if colorOrR.GetRGB then
                        local r1, g1, b1 = colorOrR:GetRGB()
                        if r1 ~= nil and g1 ~= nil and b1 ~= nil then
                            return r1, g1, b1
                        end
                    elseif colorOrR.r ~= nil and colorOrR.g ~= nil and colorOrR.b ~= nil then
                        return colorOrR.r, colorOrR.g, colorOrR.b
                    end
                elseif type(colorOrR) == "number" and type(g) == "number" and type(b) == "number" then
                    return colorOrR, g, b
                end
            end
        end

        local dispelName = GetAccessibleAuraValue(aura and aura.dispelName)
        if dispelName == "" then
            dispelName = "none"
        end

        if dispelName and DEBUFF_TYPE_COLORS and DEBUFF_TYPE_COLORS[dispelName] then
            local color = DEBUFF_TYPE_COLORS[dispelName]
            return color.r or 0, color.g or 0, color.b or 0
        end
    end

    return GetConfiguredCustomBorderColor()
end

local function ApplyBorderThickness(button, thickness)
    if not button then
        return
    end

    thickness = ClampBorderThickness(thickness)
    if button.borderTop then
        button.borderTop:SetHeight(thickness)
    end
    if button.borderBottom then
        button.borderBottom:SetHeight(thickness)
    end
    if button.borderLeft then
        button.borderLeft:SetWidth(thickness)
    end
    if button.borderRight then
        button.borderRight:SetWidth(thickness)
    end
end

local function GetDurationDisplay(button)
    if not button then
        return nil
    end

    if button.cooldown and button.cooldown.GetCountdownFontString and button.durationDisplay == nil then
        local ok, countdownFontString = pcall(button.cooldown.GetCountdownFontString, button.cooldown)
        if ok and countdownFontString then
            button.durationDisplay = countdownFontString
        end
    end

    return button.durationDisplay or button.duration
end

local function ApplyTextLayoutToButton(button, layout)
    if not button then
        return
    end

    layout = layout or GetConfiguredLayoutSettings()
    layout.iconWidth = ClampIconDimension(layout.iconWidth)
    layout.iconHeight = ClampIconDimension(layout.iconHeight)
    layout.borderThickness = ClampBorderThickness(layout.borderThickness)

    ApplyBorderThickness(button, layout.borderThickness)

    if button.count and button.count.ClearAllPoints then
        button.count:ClearAllPoints()
        button.count:SetPoint("CENTER", button, "CENTER", layout.countOffsetX, layout.countOffsetY)
        if button.count.SetFont then
            button.count:SetFont(GetTextFontPath(), ClampFontSize(layout.countFontSize), "OUTLINE")
        end
    end

    local durationDisplay = GetDurationDisplay(button)
    if durationDisplay and durationDisplay.ClearAllPoints then
        durationDisplay:ClearAllPoints()
        durationDisplay:SetPoint("CENTER", button, "CENTER", layout.durationOffsetX, layout.durationOffsetY)
        if durationDisplay.SetFont then
            durationDisplay:SetFont(GetTextFontPath(), ClampFontSize(layout.durationFontSize), "OUTLINE")
        end
    end

    if button.duration and button.duration ~= durationDisplay then
        button.duration:ClearAllPoints()
        button.duration:SetPoint("CENTER", button, "CENTER", layout.durationOffsetX, layout.durationOffsetY)
        if button.duration.SetFont then
            button.duration:SetFont(GetTextFontPath(), ClampFontSize(layout.durationFontSize), "OUTLINE")
        end
    end
end

local function ApplyButtonGeometry(button, index, metrics, isWatchRow)
    if not button or not metrics then
        return
    end

    button:ClearAllPoints()
    button:SetSize(metrics.iconWidth, metrics.iconHeight)
    button:SetPoint(
        "TOPLEFT",
        (index - 1) * (metrics.iconWidth + ICON_SPACING),
        isWatchRow and -metrics.watchRowOffset or 0
    )
end

local function ApplyTrackerGeometry(layout)
    if not trackerFrame then
        return
    end

    local metrics = GetLayoutMetrics(layout)
    trackerFrame:SetSize(metrics.totalWidth, metrics.trackerHeight)

    for i = 1, MAX_ICONS do
        ApplyButtonGeometry(buttons[i], i, metrics, false)
        ApplyButtonGeometry(watchButtons[i], i, metrics, true)
    end

    if trackerFrame.anchor then
        trackerFrame.anchor:ClearAllPoints()
        trackerFrame.anchor:SetPoint("TOPLEFT", 0, 0)
        trackerFrame.anchor:SetSize(metrics.anchorWidth, metrics.anchorHeight)
        ApplyBorderThickness(trackerFrame.anchor, metrics.borderThickness)
    end

    if trackerFrame.editOverlay then
        trackerFrame.editOverlay:ClearAllPoints()
        trackerFrame.editOverlay:SetPoint("TOPLEFT", 0, 0)
        trackerFrame.editOverlay:SetSize(metrics.anchorWidth, metrics.anchorHeight)
        ApplyBorderThickness(trackerFrame.editOverlay, metrics.borderThickness)
    end
end

local function RefreshTrackerLayout()
    local layout = GetConfiguredLayoutSettings()

    ApplyTrackerGeometry(layout)

    for i = 1, MAX_ICONS do
        ApplyTextLayoutToButton(buttons[i], layout)
        ApplyBorderThickness(watchButtons[i], layout.borderThickness)
    end
end

local function UpdateAnchorVisibility()
    if not trackerFrame or not trackerFrame.anchor then
        return
    end

    local showAnchor = addon.editModeActive == true

    if showAnchor then
        trackerFrame.anchor:Show()
    else
        trackerFrame.anchor:Hide()
    end
end

local function UpdateTrackerStrata()
    if not trackerFrame or not trackerFrame.SetFrameStrata then
        return
    end

    local editorOpen = layoutEditorFrame and layoutEditorFrame.IsShown and layoutEditorFrame:IsShown()
    trackerFrame:SetFrameStrata(editorOpen and TRACKER_EDITOR_STRATA or TRACKER_NORMAL_STRATA)
end

local function SetButtonVisible(button, visible)
    if not button then
        return
    end

    local shouldDisplay = visible and not addon.editModeActive
    local alpha = shouldDisplay and 1 or 0
    local durationDisplay = GetDurationDisplay(button)
    if button.bg then button.bg:SetAlpha(alpha) end
    if button.icon then button.icon:SetAlpha(alpha) end
    if button.count then button.count:SetAlpha(alpha) end
    if durationDisplay then durationDisplay:SetAlpha(alpha) end
    if button.duration and button.duration ~= durationDisplay then button.duration:SetAlpha(0) end
    if button.borderTop then button.borderTop:SetAlpha(alpha) end
    if button.borderBottom then button.borderBottom:SetAlpha(alpha) end
    if button.borderLeft then button.borderLeft:SetAlpha(alpha) end
    if button.borderRight then button.borderRight:SetAlpha(alpha) end
    if button.cooldown then button.cooldown:SetAlpha(alpha) end
    button.isActive = visible
    if button.EnableMouse then
        button:EnableMouse(shouldDisplay)
    end
    button:Show()
end

local function SetWatchButtonVisible(button, visible)
    if not button then
        return
    end

    local shouldDisplay = visible and not addon.editModeActive
    local alpha = shouldDisplay and 0.45 or 0
    if button.bg then button.bg:SetAlpha(alpha) end
    if button.icon then button.icon:SetAlpha(alpha) end
    if button.borderTop then button.borderTop:SetAlpha(alpha) end
    if button.borderBottom then button.borderBottom:SetAlpha(alpha) end
    if button.borderLeft then button.borderLeft:SetAlpha(alpha) end
    if button.borderRight then button.borderRight:SetAlpha(alpha) end
    button.isActive = visible
    if button.EnableMouse then
        button:EnableMouse(shouldDisplay)
    end
    button:Show()
end

local function ClearCooldown(cooldown)
    if not cooldown then
        return
    end

    if cooldown.Clear then
        cooldown:Clear()
        return
    end

    if cooldown.SetCooldown then
        cooldown:SetCooldown(0, 0)
    end
end

local function UpdateDuration(button, now)
    if not button or not button.duration then
        return
    end

    button.duration:SetText("")
end

local function ClearButton(button)
    if not button then
        return
    end

    button.currentIcon = nil
    button.auraInstanceID = nil
    button.auraIndex = nil
    button.spellId = nil
    button.queryFilter = nil
    button.expirationTime = nil

    if button.icon then
        button.icon:SetTexture(nil)
    end
    if button.count then
        button.count:SetText("")
    end
    if button.duration then
        button.duration:SetText("")
    end
    if button.cooldown then
        ClearCooldown(button.cooldown)
    end

    SetButtonVisible(button, false)
end

local function ClearWatchButton(button)
    if not button then
        return
    end

    button.currentIcon = nil
    button.spellId = nil
    if button.icon then
        button.icon:SetTexture(nil)
    end

    SetWatchButtonVisible(button, false)
end

local function ApplySpellToWatchButton(button, spellInfo)
    if not button then
        return
    end

    if not spellInfo or not spellInfo.spellId then
        ClearWatchButton(button)
        return
    end

    local iconId = 134400
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellInfo.spellId)
        if info and info.iconID then
            iconId = info.iconID
        end
    end

    button.spellId = spellInfo.spellId
    button.currentIcon = iconId
    if button.icon then
        button.icon:SetTexture(iconId)
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    if button.borderTop then button.borderTop:SetColorTexture(0, 0, 0, 1) end
    if button.borderBottom then button.borderBottom:SetColorTexture(0, 0, 0, 1) end
    if button.borderLeft then button.borderLeft:SetColorTexture(0, 0, 0, 1) end
    if button.borderRight then button.borderRight:SetColorTexture(0, 0, 0, 1) end

    SetWatchButtonVisible(button, true)
end

local function UpdateTrackerHeight(watchCount)
    if not trackerFrame then
        return
    end

    local metrics = GetLayoutMetrics()
    local height = metrics.mainRowHeight
    if watchCount and watchCount > 0 then
        height = metrics.trackerHeight
    end

    trackerFrame:SetHeight(height)
end

local function RefreshWatchButtons()
    for i = 1, MAX_ICONS do
        ClearWatchButton(watchButtons[i])
    end

    UpdateTrackerHeight(0)
    return 0
end

local function ApplyAuraToButton(button, aura)
    if not button then
        return
    end

    if not aura then
        ClearButton(button)
        return
    end

    local texID = aura.icon
    local queryFilter = aura.queryFilter
    if texID == nil and aura.auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local fullAura = C_UnitAuras.GetAuraDataByAuraInstanceID("player", aura.auraInstanceID)
        if fullAura then
            local normalized = NormalizeAura(fullAura)
            if normalized then
                normalized.queryFilter = queryFilter
                aura = normalized
            end
            texID = aura.icon
        end
    end

    if texID == nil and aura.spellId and C_Spell and C_Spell.GetSpellInfo then
        local spellInfo = C_Spell.GetSpellInfo(aura.spellId)
        if spellInfo then
            texID = spellInfo.iconID
        end
    end

    button.currentIcon = texID or 134400
    if button.icon then
        button.icon:SetTexture(button.currentIcon)
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    local r, g, b = GetBorderColor(aura)
    if button.borderTop then button.borderTop:SetColorTexture(r, g, b, 1) end
    if button.borderBottom then button.borderBottom:SetColorTexture(r, g, b, 1) end
    if button.borderLeft then button.borderLeft:SetColorTexture(r, g, b, 1) end
    if button.borderRight then button.borderRight:SetColorTexture(r, g, b, 1) end

    if button.count then
        local displayCount = nil
        if aura.auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
            displayCount = C_UnitAuras.GetAuraApplicationDisplayCount("player", aura.auraInstanceID, AURA_MIN_DISPLAY_COUNT, AURA_MAX_DISPLAY_COUNT)
        end

        if displayCount then
            button.count:SetText(displayCount)
        else
            button.count:SetText("")
        end
    end

    button.auraInstanceID = aura.auraInstanceID
    button.auraIndex = aura.auraIndex
    button.spellId = aura.spellId
    button.queryFilter = aura.queryFilter
    if aura.duration ~= nil and aura.expirationTime ~= nil then
        button.expirationTime = aura.expirationTime
        if button.cooldown then
            if button.cooldown.SetCooldownFromExpirationTime then
                button.cooldown:SetCooldownFromExpirationTime(aura.expirationTime, aura.duration)
            elseif button.cooldown.SetCooldown then
                local ok, startTime = pcall(function()
                    return aura.expirationTime - aura.duration
                end)
                if ok then
                    button.cooldown:SetCooldown(startTime, aura.duration)
                else
                    ClearCooldown(button.cooldown)
                end
            end
        end
    else
        button.expirationTime = nil
        if button.cooldown then
            ClearCooldown(button.cooldown)
        end
    end

    ApplyTextLayoutToButton(button)
    UpdateDuration(button, GetTime())
    SetButtonVisible(button, true)
end

local function RefreshButtons(reason)
    if not trackerFrame then
        return
    end

    local auras = ScanPlayerDebuffs()
    activeButtonCount = #auras
    lastAuraCount = #auras
    lastUpdateTime = GetTime()
    lastUpdateReason = reason or "manual"

    for i = 1, MAX_ICONS do
        ApplyAuraToButton(buttons[i], auras[i])
    end

    RefreshWatchButtons()

    UpdateAnchorVisibility()
    addon:CaptureDebugSnapshot(reason or "manual")
end

local function OnTrackerEvent(_, event, unit, updateInfo)
    if event == "UNIT_AURA" and unit ~= "player" then
        return
    end

    if event == "UNIT_AURA" then
        eventCounters.unitAura = eventCounters.unitAura + 1
        UpdateAuraStateFromInfo("player", updateInfo)
    elseif event == "PLAYER_REGEN_DISABLED" then
        combatStateActive = true
        eventCounters.enterCombat = eventCounters.enterCombat + 1
    elseif event == "PLAYER_REGEN_ENABLED" then
        eventCounters.leaveCombat = eventCounters.leaveCombat + 1
    elseif event == "PLAYER_ENTERING_WORLD" then
        playerGUID = UnitGUID and UnitGUID("player") or nil
        ProcessExistingHarmfulAuras("player")
    end

    if trackerFrame then
        addon:UpdateTrackedAuras(event)
    end

    if event == "PLAYER_REGEN_ENABLED" then
        combatStateActive = false
    end
end

trackerEventFrame:RegisterUnitEvent("UNIT_AURA", "player")
trackerEventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
trackerEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
trackerEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
trackerEventFrame:SetScript("OnEvent", OnTrackerEvent)

local function CloneSnapshot(snapshot)
    if not snapshot then
        return nil
    end

    local copy = {}
    for key, value in pairs(snapshot) do
        copy[key] = value
    end
    return copy
end

local function EnsureTrackerOnScreen()
    if not trackerFrame or not trackerFrame.GetCenter or not UIParent or not UIParent.GetWidth or not UIParent.GetHeight then
        return
    end

    local centerX, centerY = trackerFrame:GetCenter()
    if not centerX or not centerY then
        return
    end

    local screenWidth = UIParent:GetWidth() or 0
    local screenHeight = UIParent:GetHeight() or 0
    if centerX < 0 or centerX > screenWidth or centerY < 0 or centerY > screenHeight then
        addon:ResetTrackerPosition()
    end
end

local function RefreshButtonPresentation()
    for i = 1, MAX_ICONS do
        local button = buttons[i]
        if button then
            SetButtonVisible(button, button.isActive == true)
        end

        local watchButton = watchButtons[i]
        if watchButton then
            SetWatchButtonVisible(watchButton, watchButton.isActive == true)
        end
    end
end

local function CreateAuraButton(parent, index)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(ICON_SIZE, ICON_SIZE)
    button:SetPoint("TOPLEFT", (index - 1) * (ICON_SIZE + ICON_SPACING), 0)
    button:EnableMouse(false)

    if parent.GetFrameLevel and button.SetFrameLevel then
        button:SetFrameLevel(parent:GetFrameLevel() + 50)
    end
    if parent.GetFrameStrata and button.SetFrameStrata then
        button:SetFrameStrata(parent:GetFrameStrata())
    end

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.95)
    button.bg = bg

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon = icon

    local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cooldown:SetPoint("TOPLEFT", icon, "TOPLEFT")
    cooldown:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT")
    if cooldown.SetReverse then
        cooldown:SetReverse(true)
    end
    if cooldown.SetHideCountdownNumbers then
        cooldown:SetHideCountdownNumbers(false)
    end
    if cooldown.SetDrawEdge then
        cooldown:SetDrawEdge(false)
    end
    if cooldown.SetDrawSwipe then
        cooldown:SetDrawSwipe(true)
    end
    if cooldown.EnableMouse then
        cooldown:EnableMouse(false)
    end
    button.cooldown = cooldown

    local function CreateBorder()
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetColorTexture(0.8, 0, 0, 1)
        return border
    end

    local borderTop = CreateBorder()
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(2)

    local borderBottom = CreateBorder()
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(2)

    local borderLeft = CreateBorder()
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(2)

    local borderRight = CreateBorder()
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(2)

    button.borderTop = borderTop
    button.borderBottom = borderBottom
    button.borderLeft = borderLeft
    button.borderRight = borderRight

    local count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", -2, 2)
    button.count = count

    local duration = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    duration:SetPoint("TOP", button, "BOTTOM", 0, -1)
    button.duration = duration
    ApplyTextLayoutToButton(button)

    button:SetScript("OnEnter", function(self)
        if not self.isActive then
            return
        end

        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if self.auraIndex then
            SetTooltipAuraByIndex(GameTooltip, "player", self.auraIndex, self.queryFilter)
        elseif self.auraInstanceID and GameTooltip.SetUnitDebuffByAuraInstanceID then
            GameTooltip:SetUnitDebuffByAuraInstanceID("player", self.auraInstanceID)
        elseif self.spellId and GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.spellId)
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    SetButtonVisible(button, false)
    button:Show()
    return button
end

local function CreateWatchButton(parent, index)
    local metrics = GetLayoutMetrics()
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(metrics.iconWidth, metrics.iconHeight)
    button:SetPoint("TOPLEFT", (index - 1) * (metrics.iconWidth + ICON_SPACING), -metrics.watchRowOffset)
    button:EnableMouse(false)

    if parent.GetFrameLevel and button.SetFrameLevel then
        button:SetFrameLevel(parent:GetFrameLevel() + 40)
    end
    if parent.GetFrameStrata and button.SetFrameStrata then
        button:SetFrameStrata(parent:GetFrameStrata())
    end

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.08, 0.08, 0.08, 0.95)
    button.bg = bg

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon = icon

    local function CreateBorder()
        local border = button:CreateTexture(nil, "OVERLAY")
        border:SetColorTexture(0, 0, 0, 1)
        return border
    end

    local borderTop = CreateBorder()
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(2)

    local borderBottom = CreateBorder()
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(2)

    local borderLeft = CreateBorder()
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(2)

    local borderRight = CreateBorder()
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(2)

    button.borderTop = borderTop
    button.borderBottom = borderBottom
    button.borderLeft = borderLeft
    button.borderRight = borderRight

    button:SetScript("OnEnter", function(self)
        if not self.spellId then
            return
        end

        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.spellId)
        end
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    SetWatchButtonVisible(button, false)
    button:Show()
    return button
end

local function CreateAnchor(parent)
    local anchor = CreateFrame("Button", nil, parent, "BackdropTemplate")
    anchor:SetPoint("TOPLEFT", 0, 0)
    anchor:SetSize(ICON_SIZE * 4 + ICON_SPACING * 3, ICON_SIZE)
    anchor:EnableMouse(false)
    anchor:RegisterForDrag("LeftButton")

    local bg = anchor:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0)

    local function CreateBorder()
        local border = anchor:CreateTexture(nil, "BORDER")
        border:SetColorTexture(0, 0, 0, 0)
        return border
    end

    local borderTop = CreateBorder()
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(2)

    local borderBottom = CreateBorder()
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(2)

    local borderLeft = CreateBorder()
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(2)

    local borderRight = CreateBorder()
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(2)

    anchor:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    anchor:SetBackdropColor(0, 0, 0, 0)
    anchor:SetBackdropBorderColor(0, 0, 0, 0)

    local label = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", 68, 0)
    label:SetText("|cff00ccffDebuff Tracker|r")

    local settingsButton = CreateFrame("Button", nil, anchor, "UIPanelButtonTemplate")
    settingsButton:SetSize(62, 20)
    settingsButton:SetPoint("RIGHT", -10, 0)
    settingsButton:SetText("Layout")
    settingsButton:SetScript("OnClick", function()
        if addon.editModeActive and addon.OpenLayoutEditor then
            addon:OpenLayoutEditor()
        end
    end)

    anchor.allTex = { bg, borderTop, borderBottom, borderLeft, borderRight }
    anchor.bg = bg
    anchor.label = label
    anchor.borderTop = borderTop
    anchor.borderBottom = borderBottom
    anchor.borderLeft = borderLeft
    anchor.borderRight = borderRight
    anchor.settingsButton = settingsButton
    anchor:SetScript("OnDragStart", function()
        if addon.editModeActive and trackerFrame and trackerFrame.StartMoving then
            trackerFrame:StartMoving()
        end
    end)
    anchor:SetScript("OnDragStop", function()
        if trackerFrame and trackerFrame.StopMovingOrSizing then
            trackerFrame:StopMovingOrSizing()
        end
        if addon and addon.SaveTrackerPosition then
            addon:SaveTrackerPosition()
        end
    end)
    anchor:Hide()
    return anchor
end

function addon:CreateEditModeOverlay()
    local overlay = CreateFrame("Frame", nil, trackerFrame, "BackdropTemplate")
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetSize(ICON_SIZE * 4 + ICON_SPACING * 3, ICON_SIZE)
    if trackerFrame.GetFrameLevel and overlay.SetFrameLevel then
        overlay:SetFrameLevel(trackerFrame:GetFrameLevel() + 5)
    end

    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    overlay:SetBackdropColor(0.42, 0.56, 0.58, 0)
    overlay:SetBackdropBorderColor(0.84, 0.92, 0.92, 0)

    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0)
    overlay.bg = bg

    local function CreateBorder()
        local border = overlay:CreateTexture(nil, "BORDER")
        border:SetColorTexture(0.90, 0.96, 0.96, 0)
        return border
    end

    local borderTop = CreateBorder()
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(2)

    local borderBottom = CreateBorder()
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(2)

    local borderLeft = CreateBorder()
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(2)

    local borderRight = CreateBorder()
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(2)

    local sheen = overlay:CreateTexture(nil, "ARTWORK")
    sheen:SetPoint("TOPLEFT", 6, -6)
    sheen:SetPoint("TOPRIGHT", -6, -6)
    sheen:SetHeight(18)
    if sheen.SetGradientAlpha then
        sheen:SetGradientAlpha("VERTICAL", 1, 1, 1, 0.20, 1, 1, 1, 0.02)
    else
        sheen:SetColorTexture(1, 1, 1, 0.12)
    end
    overlay.sheen = sheen

    overlay.previewIcons = {}
    for index, textureID in ipairs(EDIT_PREVIEW_ICONS) do
        local icon = overlay:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 14 + ((index - 1) * 22), 0)
        icon:SetTexture(textureID)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetAlpha(0)
        overlay.previewIcons[index] = icon
    end

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER", 0, 0)
    label:SetText("")

    overlay.allTex = { bg, borderTop, borderBottom, borderLeft, borderRight }
    overlay.label = label
    overlay.borderTop = borderTop
    overlay.borderBottom = borderBottom
    overlay.borderLeft = borderLeft
    overlay.borderRight = borderRight
    overlay:Hide()
    trackerFrame.editOverlay = overlay
end

local function CloneBorderColor(color)
    color = type(color) == "table" and color or {}
    return {
        r = tonumber(color.r) or 0,
        g = tonumber(color.g) or 0,
        b = tonumber(color.b) or 0,
    }
end

local function CreateEditorWrappedText(parent, text, width)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
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

local function CreateEditorButton(parent, width, height, text)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, height)

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    button.bg = bg

    local top = button:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    top:SetHeight(1)

    local bottom = button:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT")
    bottom:SetHeight(1)

    local left = button:CreateTexture(nil, "BORDER")
    left:SetPoint("TOPLEFT")
    left:SetPoint("BOTTOMLEFT")
    left:SetWidth(1)

    local right = button:CreateTexture(nil, "BORDER")
    right:SetPoint("TOPRIGHT")
    right:SetPoint("BOTTOMRIGHT")
    right:SetWidth(1)

    button.borderTextures = { top, bottom, left, right }

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    button.label = label

    local function UpdateVisual(selected, hovered)
        if selected then
            bg:SetColorTexture(0.18, 0.18, 0.10, 0.96)
            for _, texture in ipairs(button.borderTextures) do
                texture:SetColorTexture(0.96, 0.78, 0.20, 1)
            end
            label:SetTextColor(1.0, 0.88, 0.35)
            return
        end

        if hovered then
            bg:SetColorTexture(0.10, 0.12, 0.16, 0.96)
            for _, texture in ipairs(button.borderTextures) do
                texture:SetColorTexture(0.42, 0.48, 0.56, 1)
            end
            label:SetTextColor(0.95, 0.95, 0.95)
            return
        end

        bg:SetColorTexture(0.05, 0.06, 0.08, 0.96)
        for _, texture in ipairs(button.borderTextures) do
            texture:SetColorTexture(0.20, 0.24, 0.30, 1)
        end
        label:SetTextColor(0.86, 0.86, 0.86)
    end

    button:SetScript("OnEnter", function(self)
        self.isHovered = true
        UpdateVisual(self.isSelected, true)
    end)
    button:SetScript("OnLeave", function(self)
        self.isHovered = false
        UpdateVisual(self.isSelected, false)
    end)

    function button:SetSelected(selected)
        self.isSelected = selected == true
        UpdateVisual(self.isSelected, self.isHovered)
    end

    button:SetSelected(false)
    return button
end

local function GetLayoutEditorPreviewBorderColor(state)
    if state.borderMode == "blizzard" and DEBUFF_TYPE_COLORS and DEBUFF_TYPE_COLORS.Magic then
        local color = DEBUFF_TYPE_COLORS.Magic
        return color.r or 0, color.g or 0, color.b or 0
    end

    local color = state.customBorderColor or {}
    return tonumber(color.r) or 0, tonumber(color.g) or 0, tonumber(color.b) or 0
end

local function SetLayoutEditorControlsShown(controls, shown)
    if not controls then
        return
    end

    for _, control in ipairs(controls) do
        if control then
            if shown then
                control:Show()
            else
                control:Hide()
            end
        end
    end
end

local function RefreshLayoutEditorPreview()
    if not layoutEditorFrame or not layoutEditorFrame.state then
        return
    end

    local state = layoutEditorFrame.state
    local layout = state.layout
    local iconWidth = ClampIconDimension(layout.iconWidth)
    local iconHeight = ClampIconDimension(layout.iconHeight)
    local borderThickness = ClampBorderThickness(layout.borderThickness)
    local selectedElementKey = layoutEditorFrame.selectedElementKey or "icon"

    if layoutEditorFrame.sizeValue then
        layoutEditorFrame.sizeValue:SetText(string.format("%d x %d", iconWidth, iconHeight))
    end
    if layoutEditorFrame.iconWidthInput then
        layoutEditorFrame.iconWidthInput:SetText(tostring(iconWidth))
    end
    if layoutEditorFrame.iconHeightInput then
        layoutEditorFrame.iconHeightInput:SetText(tostring(iconHeight))
    end
    if layoutEditorFrame.borderThicknessInput then
        layoutEditorFrame.borderThicknessInput:SetText(tostring(borderThickness))
    end

    if layoutEditorFrame.previewGroup then
        layoutEditorFrame.previewGroup:SetSize(iconWidth, iconHeight)
    end

    if layoutEditorFrame.countHandle then
        layoutEditorFrame.countHandle:ClearAllPoints()
        layoutEditorFrame.countHandle:SetPoint("CENTER", layoutEditorFrame.previewGroup, "CENTER", layout.countOffsetX, layout.countOffsetY)
        if layoutEditorFrame.countHandle.label and layoutEditorFrame.countHandle.label.SetFont then
            layoutEditorFrame.countHandle.label:SetFont(GetTextFontPath(), ClampFontSize(layout.countFontSize), "OUTLINE")
        end
        layoutEditorFrame.countHandle:SetSelected(layoutEditorFrame.selectedTextKey == "count")
    end

    if layoutEditorFrame.durationHandle then
        layoutEditorFrame.durationHandle:ClearAllPoints()
        layoutEditorFrame.durationHandle:SetPoint("CENTER", layoutEditorFrame.previewGroup, "CENTER", layout.durationOffsetX, layout.durationOffsetY)
        if layoutEditorFrame.durationHandle.label and layoutEditorFrame.durationHandle.label.SetFont then
            layoutEditorFrame.durationHandle.label:SetFont(GetTextFontPath(), ClampFontSize(layout.durationFontSize), "OUTLINE")
        end
        layoutEditorFrame.durationHandle:SetSelected(layoutEditorFrame.selectedTextKey == "duration")
    end

    if layoutEditorFrame.topResizeHandle then
        layoutEditorFrame.topResizeHandle:ClearAllPoints()
        layoutEditorFrame.topResizeHandle:SetPoint("BOTTOM", layoutEditorFrame.previewGroup, "TOP", 0, 14)
        layoutEditorFrame.topResizeHandle:SetSelected(selectedElementKey == "icon")
    end
    if layoutEditorFrame.leftResizeHandle then
        layoutEditorFrame.leftResizeHandle:ClearAllPoints()
        layoutEditorFrame.leftResizeHandle:SetPoint("RIGHT", layoutEditorFrame.previewGroup, "LEFT", -14, 0)
        layoutEditorFrame.leftResizeHandle:SetSelected(selectedElementKey == "icon")
    end

    if layoutEditorFrame.selectionValue then
        if selectedElementKey == "duration" then
            layoutEditorFrame.selectionValue:SetText("Selected: Duration")
        elseif selectedElementKey == "count" then
            layoutEditorFrame.selectionValue:SetText("Selected: Count")
        else
            layoutEditorFrame.selectionValue:SetText("Selected: Icon")
        end
    end

    if layoutEditorFrame.selectedTextHelp then
        if layoutEditorFrame.selectedTextKey == "duration" then
            layoutEditorFrame.selectedTextHelp:SetText("Duration uses Blizzard's native cooldown text because aura timing values can be secret.")
        else
            layoutEditorFrame.selectedTextHelp:SetText("2 = stack count. Drag to move it, then adjust the font size below.")
        end
    end

    if layoutEditorFrame.fontSizeInput then
        local fontSize = layoutEditorFrame.selectedTextKey == "duration" and layout.durationFontSize or layout.countFontSize
        layoutEditorFrame.fontSizeInput:SetText(tostring(ClampFontSize(fontSize)))
    end

    local r, g, b = GetLayoutEditorPreviewBorderColor(state)
    if layoutEditorFrame.previewBorderTop then layoutEditorFrame.previewBorderTop:SetColorTexture(r, g, b, 1) end
    if layoutEditorFrame.previewBorderBottom then layoutEditorFrame.previewBorderBottom:SetColorTexture(r, g, b, 1) end
    if layoutEditorFrame.previewBorderLeft then layoutEditorFrame.previewBorderLeft:SetColorTexture(r, g, b, 1) end
    if layoutEditorFrame.previewBorderRight then layoutEditorFrame.previewBorderRight:SetColorTexture(r, g, b, 1) end
    ApplyBorderThickness(layoutEditorFrame.previewGroup, borderThickness)

    if layoutEditorFrame.customModeButton then
        layoutEditorFrame.customModeButton:SetSelected(state.borderMode ~= "blizzard")
    end
    if layoutEditorFrame.blizzardModeButton then
        layoutEditorFrame.blizzardModeButton:SetSelected(state.borderMode == "blizzard")
    end
    local customColor = state.customBorderColor or {}
    if layoutEditorFrame.colorPreview then
        layoutEditorFrame.colorPreview:SetColorTexture(tonumber(customColor.r) or 0, tonumber(customColor.g) or 0, tonumber(customColor.b) or 0, 1)
    end
    if layoutEditorFrame.colorValueText then
        layoutEditorFrame.colorValueText:SetText(string.format("#%02X%02X%02X",
            math.floor(((tonumber(customColor.r) or 0) * 255) + 0.5),
            math.floor(((tonumber(customColor.g) or 0) * 255) + 0.5),
            math.floor(((tonumber(customColor.b) or 0) * 255) + 0.5)))
    end

    SetLayoutEditorControlsShown(layoutEditorFrame.iconControls, selectedElementKey == "icon")
    SetLayoutEditorControlsShown(layoutEditorFrame.textControls, selectedElementKey ~= "icon")
    SetLayoutEditorControlsShown(layoutEditorFrame.customColorControls, selectedElementKey == "icon" and state.borderMode ~= "blizzard")
end

local function SelectLayoutEditorIcon()
    if not layoutEditorFrame then
        return
    end

    layoutEditorFrame.selectedElementKey = "icon"
    RefreshLayoutEditorPreview()
end

local function SelectLayoutEditorTextHandle(textKey)
    if not layoutEditorFrame then
        return
    end

    layoutEditorFrame.selectedTextKey = textKey == "duration" and "duration" or "count"
    layoutEditorFrame.selectedElementKey = layoutEditorFrame.selectedTextKey
    RefreshLayoutEditorPreview()
end

local function AdjustSelectedLayoutFontSize(delta)
    if not layoutEditorFrame or not layoutEditorFrame.state then
        return
    end

    local layout = layoutEditorFrame.state.layout
    local fontKey = layoutEditorFrame.selectedTextKey == "duration" and "durationFontSize" or "countFontSize"
    layout[fontKey] = ClampFontSize((layout[fontKey] or 14) + delta)
    RefreshLayoutEditorPreview()
end

local function BeginLayoutHandleDrag(handle, offsetXKey, offsetYKey)
    if not layoutEditorFrame or not layoutEditorFrame.state or not GetCursorPosition then
        return
    end

    local scale = UIParent and UIParent.GetScale and UIParent:GetScale() or 1
    local cursorX, cursorY = GetCursorPosition()
    handle.dragging = true
    handle.dragStartCursorX = cursorX / scale
    handle.dragStartCursorY = cursorY / scale
    handle.dragStartOffsetX = layoutEditorFrame.state.layout[offsetXKey]
    handle.dragStartOffsetY = layoutEditorFrame.state.layout[offsetYKey]
    handle.offsetXKey = offsetXKey
    handle.offsetYKey = offsetYKey

    handle:SetScript("OnUpdate", function(self)
        local nextCursorX, nextCursorY = GetCursorPosition()
        local frameScale = UIParent and UIParent.GetScale and UIParent:GetScale() or 1
        local deltaX = (nextCursorX / frameScale) - self.dragStartCursorX
        local deltaY = (nextCursorY / frameScale) - self.dragStartCursorY
        layoutEditorFrame.state.layout[self.offsetXKey] = math.floor(self.dragStartOffsetX + deltaX + 0.5)
        layoutEditorFrame.state.layout[self.offsetYKey] = math.floor(self.dragStartOffsetY + deltaY + 0.5)
        RefreshLayoutEditorPreview()
    end)
end

local function EndLayoutHandleDrag(handle)
    if not handle then
        return
    end

    handle.dragging = false
    handle:SetScript("OnUpdate", nil)
end

local function BeginLayoutResizeDrag(handle, widthKey, heightKey, directionX, directionY)
    if not layoutEditorFrame or not layoutEditorFrame.state or not GetCursorPosition then
        return
    end

    local scale = UIParent and UIParent.GetScale and UIParent:GetScale() or 1
    local cursorX, cursorY = GetCursorPosition()
    handle.dragStartCursorX = cursorX / scale
    handle.dragStartCursorY = cursorY / scale
    handle.widthKey = widthKey
    handle.heightKey = heightKey
    handle.dragStartWidth = widthKey and layoutEditorFrame.state.layout[widthKey] or nil
    handle.dragStartHeight = heightKey and layoutEditorFrame.state.layout[heightKey] or nil
    handle.directionX = directionX or 0
    handle.directionY = directionY or 0

    handle:SetScript("OnUpdate", function(self)
        local nextCursorX, nextCursorY = GetCursorPosition()
        local frameScale = UIParent and UIParent.GetScale and UIParent:GetScale() or 1
        local deltaX = (nextCursorX / frameScale) - self.dragStartCursorX
        local deltaY = (nextCursorY / frameScale) - self.dragStartCursorY

        if self.widthKey then
            local nextWidth = self.dragStartWidth + (deltaX * self.directionX)
            layoutEditorFrame.state.layout[self.widthKey] = ClampIconDimension(nextWidth)
        end
        if self.heightKey then
            local nextHeight = self.dragStartHeight + (deltaY * self.directionY)
            layoutEditorFrame.state.layout[self.heightKey] = ClampIconDimension(nextHeight)
        end
        RefreshLayoutEditorPreview()
    end)
end

local function OpenLayoutEditorColorPicker()
    if not layoutEditorFrame or not layoutEditorFrame.state then
        return
    end

    if not ColorPickerFrame or not ColorPickerFrame.SetupColorPickerAndShow then
        return
    end

    local current = CloneBorderColor(layoutEditorFrame.state.customBorderColor)
    ColorPickerFrame:SetupColorPickerAndShow({
        r = current.r,
        g = current.g,
        b = current.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            layoutEditorFrame.state.borderMode = "custom"
            layoutEditorFrame.state.customBorderColor = { r = r, g = g, b = b }
            RefreshLayoutEditorPreview()
        end,
        cancelFunc = function()
            layoutEditorFrame.state.customBorderColor = current
            RefreshLayoutEditorPreview()
        end,
    })
end

local function CommitLayoutEditorState()
    if not layoutEditorFrame or not layoutEditorFrame.state or not addon or not addon.db then
        return
    end

    addon.db.layout = CloneLayoutSettings(layoutEditorFrame.state.layout)
    addon.db.borderMode = layoutEditorFrame.state.borderMode
    addon.db.customBorderColor = CloneBorderColor(layoutEditorFrame.state.customBorderColor)

    RefreshTrackerLayout()
    addon:UpdateTrackedAuras("layout-editor-apply")
end

local function ResetLayoutEditorState()
    if not layoutEditorFrame then
        return
    end

    layoutEditorFrame.state = {
        layout = GetDefaultLayoutSettings(),
        borderMode = "custom",
        customBorderColor = { r = 0, g = 0, b = 0 },
    }
    layoutEditorFrame.selectedElementKey = "icon"
    layoutEditorFrame.selectedTextKey = "count"
    RefreshLayoutEditorPreview()
end

local function LoadLayoutEditorState()
    layoutEditorFrame.state = {
        layout = CloneLayoutSettings(GetConfiguredLayoutSettings()),
        borderMode = addon and addon.db and addon.db.borderMode or "custom",
        customBorderColor = CloneBorderColor(addon and addon.db and addon.db.customBorderColor or nil),
    }
    layoutEditorFrame.selectedElementKey = layoutEditorFrame.selectedElementKey or "icon"
    layoutEditorFrame.selectedTextKey = layoutEditorFrame.selectedTextKey or "count"
end

local function CreateLayoutHandle(parent, text)
    local handle = CreateFrame("Button", nil, parent)
    handle:SetSize(44, 20)
    if parent.GetFrameStrata and handle.SetFrameStrata then
        handle:SetFrameStrata(parent:GetFrameStrata())
    end
    if parent.GetFrameLevel and handle.SetFrameLevel then
        handle:SetFrameLevel(parent:GetFrameLevel() + 30)
    end

    local bg = handle:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0)
    handle.bg = bg

    local label = handle:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    label:SetPoint("CENTER")
    label:SetText(text)
    handle.label = label

    handle:SetMovable(true)
    handle:EnableMouse(true)
    handle:SetScript("OnEnter", function(self)
        if self.isSelected then
            return
        end
        if self.label then
            self.label:SetTextColor(1, 0.85, 0.3)
        end
    end)
    handle:SetScript("OnLeave", function(self)
        if self.isSelected then
            return
        end
        if self.label then
            self.label:SetTextColor(1, 1, 1)
        end
    end)

    function handle:SetSelected(selected)
        self.isSelected = selected == true
        if self.bg then
            self.bg:SetColorTexture(0.18, 0.18, 0.10, self.isSelected and 0.55 or 0)
        end
        if self.label then
            if self.isSelected then
                self.label:SetTextColor(1.0, 0.88, 0.35)
            else
                self.label:SetTextColor(1, 1, 1)
            end
        end
    end

    handle:SetSelected(false)
    return handle
end

function addon:CreateLayoutEditor()
    if layoutEditorFrame then
        return layoutEditorFrame
    end

    local frame = CreateFrame("Frame", "DebuffAddonLayoutEditorFrame", UIParent, "BackdropTemplate")
    frame:SetSize(720, 540)
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
    frame:SetBackdropColor(0.05, 0.05, 0.06, 0.97)
    frame:SetBackdropBorderColor(0.36, 0.36, 0.38, 1)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16)
    title:SetText("|cff00ccffDebuff Tracker|r Layout")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", 18, -38)
    subtitle:SetText("Open this from Edit Mode. Drag the left edge to widen and the top edge to increase height.")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local previewArea = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    previewArea:SetPoint("TOPLEFT", 18, -66)
    previewArea:SetSize(410, 320)
    previewArea:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    previewArea:SetBackdropColor(0.07, 0.07, 0.08, 0.94)
    previewArea:SetBackdropBorderColor(0.22, 0.22, 0.24, 1)

    local previewHint = previewArea:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    previewHint:SetPoint("BOTTOM", 0, 14)
    previewHint:SetText("Drag the left edge for width, the top edge for height, and drag 2 / 8.8 to reposition text")

    local previewGroup = CreateFrame("Frame", nil, previewArea)
    previewGroup:SetPoint("BOTTOMRIGHT", previewArea, "CENTER", 42, -18)
    previewGroup:SetSize(72, 72)
    previewGroup:EnableMouse(true)
    previewGroup:SetScript("OnMouseDown", function()
        SelectLayoutEditorIcon()
    end)
    frame.previewGroup = previewGroup

    local previewIcon = previewGroup:CreateTexture(nil, "ARTWORK")
    previewIcon:SetPoint("TOPLEFT", 2, -2)
    previewIcon:SetPoint("BOTTOMRIGHT", -2, 2)
    previewIcon:SetTexture(132345)

    local previewBg = previewGroup:CreateTexture(nil, "BACKGROUND")
    previewBg:SetAllPoints()
    previewBg:SetColorTexture(0.08, 0.08, 0.08, 0.95)

    local previewBorderTop = previewGroup:CreateTexture(nil, "OVERLAY")
    previewBorderTop:SetPoint("TOPLEFT")
    previewBorderTop:SetPoint("TOPRIGHT")
    previewBorderTop:SetHeight(2)

    local previewBorderBottom = previewGroup:CreateTexture(nil, "OVERLAY")
    previewBorderBottom:SetPoint("BOTTOMLEFT")
    previewBorderBottom:SetPoint("BOTTOMRIGHT")
    previewBorderBottom:SetHeight(2)

    local previewBorderLeft = previewGroup:CreateTexture(nil, "OVERLAY")
    previewBorderLeft:SetPoint("TOPLEFT")
    previewBorderLeft:SetPoint("BOTTOMLEFT")
    previewBorderLeft:SetWidth(2)

    local previewBorderRight = previewGroup:CreateTexture(nil, "OVERLAY")
    previewBorderRight:SetPoint("TOPRIGHT")
    previewBorderRight:SetPoint("BOTTOMRIGHT")
    previewBorderRight:SetWidth(2)

    frame.previewBorderTop = previewBorderTop
    frame.previewBorderBottom = previewBorderBottom
    frame.previewBorderLeft = previewBorderLeft
    frame.previewBorderRight = previewBorderRight
    previewGroup.borderTop = previewBorderTop
    previewGroup.borderBottom = previewBorderBottom
    previewGroup.borderLeft = previewBorderLeft
    previewGroup.borderRight = previewBorderRight

    local countHandle = CreateLayoutHandle(previewArea, "2")
    countHandle:SetScript("OnMouseDown", function(self)
        SelectLayoutEditorTextHandle("count")
        BeginLayoutHandleDrag(self, "countOffsetX", "countOffsetY")
    end)
    countHandle:SetScript("OnMouseUp", function(self)
        EndLayoutHandleDrag(self)
    end)
    frame.countHandle = countHandle

    local durationHandle = CreateLayoutHandle(previewArea, "8.8")
    durationHandle:SetScript("OnMouseDown", function(self)
        SelectLayoutEditorTextHandle("duration")
        BeginLayoutHandleDrag(self, "durationOffsetX", "durationOffsetY")
    end)
    durationHandle:SetScript("OnMouseUp", function(self)
        EndLayoutHandleDrag(self)
    end)
    frame.durationHandle = durationHandle

    local topResizeHandle = CreateLayoutHandle(previewArea, "^")
    topResizeHandle:SetScript("OnMouseDown", function(self)
        SelectLayoutEditorIcon()
        BeginLayoutResizeDrag(self, nil, "iconHeight", 0, 1)
    end)
    topResizeHandle:SetScript("OnMouseUp", function(self)
        EndLayoutHandleDrag(self)
    end)
    frame.topResizeHandle = topResizeHandle

    local leftResizeHandle = CreateLayoutHandle(previewArea, "<")
    leftResizeHandle:SetScript("OnMouseDown", function(self)
        SelectLayoutEditorIcon()
        BeginLayoutResizeDrag(self, "iconWidth", nil, -1, 0)
    end)
    leftResizeHandle:SetScript("OnMouseUp", function(self)
        EndLayoutHandleDrag(self)
    end)
    frame.leftResizeHandle = leftResizeHandle

    local controls = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    controls:SetPoint("TOPRIGHT", -18, -66)
    controls:SetSize(256, 430)
    controls:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    controls:SetBackdropColor(0.07, 0.07, 0.08, 0.94)
    controls:SetBackdropBorderColor(0.22, 0.22, 0.24, 1)
    frame.iconControls = {}
    frame.textControls = {}
    frame.customColorControls = {}

    local function TrackControl(control, groupName)
        if not control or not groupName then
            return control
        end
        frame[groupName][#frame[groupName] + 1] = control
        return control
    end

    local selectionLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectionLabel:SetPoint("TOPLEFT", 14, -16)
    selectionLabel:SetText("Selection")

    local selectionValue = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    selectionValue:SetPoint("TOPLEFT", 14, -36)
    selectionValue:SetText("Selected: Icon")
    frame.selectionValue = selectionValue

    local sizeLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeLabel:SetPoint("TOPLEFT", 14, -70)
    sizeLabel:SetText("Icon Size")
    TrackControl(sizeLabel, "iconControls")

    local sizeValue = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeValue:SetPoint("TOPLEFT", 14, -92)
    sizeValue:SetText("36 x 36")
    frame.sizeValue = sizeValue
    TrackControl(sizeValue, "iconControls")

    local widthLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    widthLabel:SetPoint("TOPLEFT", 14, -118)
    widthLabel:SetText("Width")
    TrackControl(widthLabel, "iconControls")

    local heightLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    heightLabel:SetPoint("TOPLEFT", 92, -118)
    heightLabel:SetText("Height")
    TrackControl(heightLabel, "iconControls")

    local widthInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    widthInput:SetSize(52, 22)
    widthInput:SetPoint("TOPLEFT", 14, -138)
    widthInput:SetAutoFocus(false)
    widthInput:SetNumeric(true)
    frame.iconWidthInput = widthInput
    TrackControl(widthInput, "iconControls")

    local heightInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    heightInput:SetSize(52, 22)
    heightInput:SetPoint("LEFT", widthInput, "RIGHT", 12, 0)
    heightInput:SetAutoFocus(false)
    heightInput:SetNumeric(true)
    frame.iconHeightInput = heightInput
    TrackControl(heightInput, "iconControls")

    local function ApplyManualIconSize()
        if not frame.state then
            return
        end

        frame.state.layout.iconWidth = ClampIconDimension(widthInput:GetText())
        frame.state.layout.iconHeight = ClampIconDimension(heightInput:GetText())
        RefreshLayoutEditorPreview()
    end

    widthInput:SetScript("OnEnterPressed", function(self)
        ApplyManualIconSize()
        self:ClearFocus()
    end)
    heightInput:SetScript("OnEnterPressed", function(self)
        ApplyManualIconSize()
        self:ClearFocus()
    end)

    local sizeApply = CreateEditorButton(controls, 86, 22, "Set Size")
    sizeApply:SetPoint("LEFT", heightInput, "RIGHT", 10, 0)
    sizeApply:SetScript("OnClick", ApplyManualIconSize)
    TrackControl(sizeApply, "iconControls")

    local sizeHelp = CreateEditorWrappedText(controls, "The left handle changes width. The top handle changes height. You can also enter exact values here.", 226)
    sizeHelp:SetPoint("TOPLEFT", 14, -170)
    TrackControl(sizeHelp, "iconControls")

    local borderThicknessLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    borderThicknessLabel:SetPoint("TOPLEFT", 14, -214)
    borderThicknessLabel:SetText("Border Thickness")
    TrackControl(borderThicknessLabel, "iconControls")

    local borderThicknessInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    borderThicknessInput:SetSize(52, 22)
    borderThicknessInput:SetPoint("TOPLEFT", 14, -236)
    borderThicknessInput:SetAutoFocus(false)
    borderThicknessInput:SetNumeric(true)
    frame.borderThicknessInput = borderThicknessInput
    TrackControl(borderThicknessInput, "iconControls")

    local borderThicknessMinus = CreateEditorButton(controls, 34, 22, "-")
    borderThicknessMinus:SetPoint("LEFT", borderThicknessInput, "RIGHT", 8, 0)
    borderThicknessMinus:SetScript("OnClick", function()
        if not frame.state then
            return
        end
        frame.state.layout.borderThickness = ClampBorderThickness((frame.state.layout.borderThickness or 2) - 1)
        RefreshLayoutEditorPreview()
    end)
    TrackControl(borderThicknessMinus, "iconControls")

    local borderThicknessPlus = CreateEditorButton(controls, 34, 22, "+")
    borderThicknessPlus:SetPoint("LEFT", borderThicknessMinus, "RIGHT", 6, 0)
    borderThicknessPlus:SetScript("OnClick", function()
        if not frame.state then
            return
        end
        frame.state.layout.borderThickness = ClampBorderThickness((frame.state.layout.borderThickness or 2) + 1)
        RefreshLayoutEditorPreview()
    end)
    TrackControl(borderThicknessPlus, "iconControls")

    local borderThicknessApply = CreateEditorButton(controls, 86, 22, "Apply")
    borderThicknessApply:SetPoint("LEFT", borderThicknessPlus, "RIGHT", 6, 0)
    borderThicknessApply:SetScript("OnClick", function()
        if not frame.state then
            return
        end
        frame.state.layout.borderThickness = ClampBorderThickness(borderThicknessInput:GetText())
        RefreshLayoutEditorPreview()
    end)
    TrackControl(borderThicknessApply, "iconControls")

    local selectedTextLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    selectedTextLabel:SetPoint("TOPLEFT", 14, -70)
    selectedTextLabel:SetText("Selected Text")
    TrackControl(selectedTextLabel, "textControls")

    local selectedTextValue = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    selectedTextValue:SetPoint("TOPLEFT", 14, -92)
    selectedTextValue:SetText("Selected: Count")
    frame.selectedTextValue = selectedTextValue
    TrackControl(selectedTextValue, "textControls")

    local selectedTextHelp = CreateEditorWrappedText(controls, "", 226)
    selectedTextHelp:SetPoint("TOPLEFT", 14, -112)
    frame.selectedTextHelp = selectedTextHelp
    TrackControl(selectedTextHelp, "textControls")

    local fontSizeLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fontSizeLabel:SetPoint("TOPLEFT", 14, -156)
    fontSizeLabel:SetText("Font Size")
    TrackControl(fontSizeLabel, "textControls")

    local fontSizeInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    fontSizeInput:SetSize(52, 22)
    fontSizeInput:SetPoint("TOPLEFT", 14, -178)
    fontSizeInput:SetAutoFocus(false)
    fontSizeInput:SetNumeric(true)
    frame.fontSizeInput = fontSizeInput
    TrackControl(fontSizeInput, "textControls")

    local fontMinus = CreateEditorButton(controls, 34, 22, "-")
    fontMinus:SetPoint("LEFT", fontSizeInput, "RIGHT", 8, 0)
    fontMinus:SetScript("OnClick", function()
        AdjustSelectedLayoutFontSize(-1)
    end)
    TrackControl(fontMinus, "textControls")

    local fontPlus = CreateEditorButton(controls, 34, 22, "+")
    fontPlus:SetPoint("LEFT", fontMinus, "RIGHT", 6, 0)
    fontPlus:SetScript("OnClick", function()
        AdjustSelectedLayoutFontSize(1)
    end)
    TrackControl(fontPlus, "textControls")

    local fontApply = CreateEditorButton(controls, 86, 22, "Set Font")
    fontApply:SetPoint("LEFT", fontPlus, "RIGHT", 6, 0)
    fontApply:SetScript("OnClick", function()
        if not frame.state then
            return
        end
        local fontKey = frame.selectedTextKey == "duration" and "durationFontSize" or "countFontSize"
        frame.state.layout[fontKey] = ClampFontSize(fontSizeInput:GetText())
        RefreshLayoutEditorPreview()
    end)
    TrackControl(fontApply, "textControls")

    local modeLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeLabel:SetPoint("TOPLEFT", 14, -268)
    modeLabel:SetText("Border Mode")
    TrackControl(modeLabel, "iconControls")

    local customModeButton = CreateEditorButton(controls, 110, 22, "Custom")
    customModeButton:SetPoint("TOPLEFT", 14, -292)
    customModeButton:SetScript("OnClick", function()
        frame.state.borderMode = "custom"
        RefreshLayoutEditorPreview()
    end)
    frame.customModeButton = customModeButton
    TrackControl(customModeButton, "iconControls")

    local blizzardModeButton = CreateEditorButton(controls, 110, 22, "Blizzard")
    blizzardModeButton:SetPoint("LEFT", customModeButton, "RIGHT", 8, 0)
    blizzardModeButton:SetScript("OnClick", function()
        frame.state.borderMode = "blizzard"
        RefreshLayoutEditorPreview()
    end)
    frame.blizzardModeButton = blizzardModeButton
    TrackControl(blizzardModeButton, "iconControls")

    local colorLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colorLabel:SetPoint("TOPLEFT", 14, -332)
    colorLabel:SetText("Custom Border Color")
    TrackControl(colorLabel, "iconControls")
    TrackControl(colorLabel, "customColorControls")

    local colorApply = CreateEditorButton(controls, 96, 22, "Pick Color")
    colorApply:SetPoint("TOPLEFT", 14, -354)
    colorApply:SetScript("OnClick", function()
        OpenLayoutEditorColorPicker()
    end)
    frame.colorApplyButton = colorApply
    TrackControl(colorApply, "iconControls")
    TrackControl(colorApply, "customColorControls")

    local colorPreviewHolder = CreateFrame("Frame", nil, controls, "BackdropTemplate")
    colorPreviewHolder:SetSize(54, 24)
    colorPreviewHolder:SetPoint("LEFT", colorApply, "RIGHT", 10, 0)
    colorPreviewHolder:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    colorPreviewHolder:SetBackdropColor(0.02, 0.02, 0.02, 1)
    colorPreviewHolder:SetBackdropBorderColor(0.30, 0.30, 0.32, 1)

    local colorPreview = colorPreviewHolder:CreateTexture(nil, "ARTWORK")
    colorPreview:SetPoint("TOPLEFT", 3, -3)
    colorPreview:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.colorPreview = colorPreview
    TrackControl(colorPreviewHolder, "iconControls")
    TrackControl(colorPreviewHolder, "customColorControls")

    local colorValueText = controls:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    colorValueText:SetPoint("LEFT", colorPreviewHolder, "RIGHT", 8, 0)
    colorValueText:SetText("#000000")
    frame.colorValueText = colorValueText
    TrackControl(colorValueText, "iconControls")
    TrackControl(colorValueText, "customColorControls")

    local layoutInfo = CreateEditorWrappedText(
        controls,
        "The preview uses the real icon size. 2 is stack count, 8.8 is duration, and Pick Color opens the Blizzard color picker.",
        226
    )
    layoutInfo:SetPoint("TOPLEFT", 14, -394)
    TrackControl(layoutInfo, "iconControls")

    local cancelButton = CreateEditorButton(frame, 180, 24, "Cancel")
    cancelButton:SetPoint("BOTTOMLEFT", 18, 18)
    cancelButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    local resetButton = CreateEditorButton(frame, 180, 24, "Reset")
    resetButton:SetPoint("BOTTOM", 0, 18)
    resetButton:SetScript("OnClick", function()
        ResetLayoutEditorState()
    end)

    local applyButton = CreateEditorButton(frame, 180, 24, "Apply")
    applyButton:SetPoint("BOTTOMRIGHT", -18, 18)
    applyButton:SetScript("OnClick", function()
        CommitLayoutEditorState()
    end)

    layoutEditorFrame = frame
    frame.selectedElementKey = "icon"
    frame.selectedTextKey = "count"
    frame:SetScript("OnHide", function()
        if addon and addon.editModeActive then
            if trackerFrame and trackerFrame.editOverlay then
                trackerFrame.editOverlay:Show()
            end
            UpdateTrackerStrata()
            UpdateAnchorVisibility()
        end
    end)
    return frame
end

function addon:OpenLayoutEditor()
    if not addon.editModeActive then
        return
    end

    if not layoutEditorFrame then
        addon:CreateLayoutEditor()
    end

    LoadLayoutEditorState()
    RefreshLayoutEditorPreview()
    UpdateTrackerStrata()
    layoutEditorFrame:Show()
    UpdateTrackerStrata()
    UpdateAnchorVisibility()
end

function addon:SetupEditModeHooks()
    if not EditModeManagerFrame then
        return
    end

    if EditModeManagerFrame.EnterEditMode then
        hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
            C_Timer.After(0, function()
                addon:OnEditModeEnter()
            end)
        end)
    end

    if EditModeManagerFrame.ExitEditMode then
        hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
            C_Timer.After(0, function()
                addon:OnEditModeExit()
            end)
        end)
    end
end

function addon:OnEditModeEnter()
    if not trackerFrame or addon.editModeActive then
        return
    end

    addon.editModeActive = true
    trackerFrame:SetMovable(true)
    trackerFrame:EnableMouse(true)
    trackerFrame:RegisterForDrag("LeftButton")
    trackerFrame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    trackerFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        addon:SaveTrackerPosition()
    end)

    local overlay = trackerFrame.editOverlay
    overlay:Show()
    overlay:SetBackdropColor(0.48, 0.62, 0.64, 0.34)
    overlay:SetBackdropBorderColor(0.86, 0.94, 0.94, 0.95)
    overlay.bg:SetColorTexture(0, 0, 0, 0)
    for _, texture in ipairs(overlay.allTex) do
        texture:SetVertexColor(0.88, 0.96, 0.96, 0.22)
    end
    overlay.bg:SetVertexColor(1, 1, 1, 1)
    if overlay.previewIcons then
        for _, icon in ipairs(overlay.previewIcons) do
            icon:SetAlpha(0.95)
        end
    end
    overlay.label:SetText("")
    if trackerFrame.anchor and trackerFrame.anchor.EnableMouse then
        trackerFrame.anchor:EnableMouse(true)
    end
    UpdateTrackerStrata()
    RefreshButtonPresentation()
    UpdateAnchorVisibility()
end

function addon:OnEditModeExit()
    if not trackerFrame or not addon.editModeActive then
        return
    end

    addon.editModeActive = false
    trackerFrame:SetMovable(false)
    trackerFrame:EnableMouse(false)
    trackerFrame:RegisterForDrag()
    trackerFrame:SetScript("OnDragStart", nil)
    trackerFrame:SetScript("OnDragStop", nil)

    local overlay = trackerFrame.editOverlay
    overlay.bg:SetColorTexture(0, 0, 0, 0)
    overlay:SetBackdropColor(0, 0, 0, 0)
    overlay:SetBackdropBorderColor(0, 0, 0, 0)
    for _, texture in ipairs(overlay.allTex) do
        texture:SetVertexColor(0, 0, 0, 0)
    end
    if overlay.previewIcons then
        for _, icon in ipairs(overlay.previewIcons) do
            icon:SetAlpha(0)
        end
    end
    overlay.label:SetText("")
    overlay:Hide()
    if trackerFrame.anchor and trackerFrame.anchor.EnableMouse then
        trackerFrame.anchor:EnableMouse(false)
    end
    if layoutEditorFrame and layoutEditorFrame.Hide then
        layoutEditorFrame:Hide()
    end

    addon:SaveTrackerPosition()
    UpdateTrackerStrata()
    RefreshButtonPresentation()
    UpdateAnchorVisibility()
end

function addon:UpdateTrackedAuras(reason)
    RefreshButtons(reason or "manual")
end

function addon:UpdateDurationTexts()
    local now = GetTime()
    for i = 1, MAX_ICONS do
        local button = buttons[i]
        if button and button:IsShown() then
            UpdateDuration(button, now)
        end
    end
end

function addon:CaptureDebugSnapshot(reason)
    local firstButton = buttons[1]
    local firstAura = ScanPlayerDebuffs()[1]
    local snapshot = {
        buttonShown = firstButton and firstButton:IsShown() or nil,
        buttonAlpha = firstButton and firstButton.icon and firstButton.icon.GetAlpha and firstButton.icon:GetAlpha() or nil,
        firstSpell = firstButton and firstButton.spellId or nil,
        firstIcon = firstButton and firstButton.currentIcon or nil,
        firstTexture = firstButton and firstButton.icon and firstButton.icon.GetTexture and firstButton.icon:GetTexture() or nil,
        firstDuration = firstButton and firstButton.expirationTime or nil,
        scanCount = #ScanPlayerDebuffs(),
        auraSpell = firstAura and firstAura.spellId or nil,
        auraIcon = firstAura and firstAura.icon or nil,
        lastAuraCount = lastAuraCount,
        lastUpdateTime = lastUpdateTime,
        lastUpdateReason = reason or lastUpdateReason,
        inCombat = combatStateActive or IsInCombat(),
        counters = CloneSnapshot(eventCounters),
    }

    lastDebugSnapshot = CloneSnapshot(snapshot)
    if snapshot.inCombat then
        lastCombatSnapshot = CloneSnapshot(snapshot)
    end
end

function addon:GetTrackerDebugInfo()
    if not lastDebugSnapshot then
        addon:CaptureDebugSnapshot(lastUpdateReason)
    end

    local info = CloneSnapshot(lastDebugSnapshot) or {}
    info.lastCombat = CloneSnapshot(lastCombatSnapshot)
    return info
end

function addon:InitTracker()
    if trackerFrame then
        return
    end

    local metrics = GetLayoutMetrics()
    trackerFrame = CreateFrame("Frame", nil, UIParent)
    trackerFrame:SetSize(metrics.totalWidth, metrics.trackerHeight)
    trackerFrame:SetFrameStrata(TRACKER_NORMAL_STRATA)
    trackerFrame:SetClampedToScreen(true)
    if trackerFrame.SetFrameLevel then
        trackerFrame:SetFrameLevel(5)
    end

    local pos = addon.db.framePosition
    trackerFrame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    trackerFrame:Show()

    for i = 1, MAX_ICONS do
        buttons[i] = CreateAuraButton(trackerFrame, i)
        watchButtons[i] = CreateWatchButton(trackerFrame, i)
    end

    trackerFrame.anchor = CreateAnchor(trackerFrame)

    addon:CreateEditModeOverlay()
    addon:SetupEditModeHooks()
    RefreshTrackerLayout()
    EnsureTrackerOnScreen()

    tickFrame = CreateFrame("Frame")
    local elapsed = 0
    local combatPollElapsed = 0
    tickFrame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        combatPollElapsed = combatPollElapsed + dt

        if elapsed >= 0.1 then
            elapsed = 0
            addon:UpdateDurationTexts()
        end

        if IsInCombat() and combatPollElapsed >= 0.2 then
            combatPollElapsed = 0
            combatStateActive = true
            eventCounters.combatPoll = eventCounters.combatPoll + 1
            addon:UpdateTrackedAuras("combat-poll")
        elseif not IsInCombat() then
            combatPollElapsed = 0
        end
    end)
    tickFrame:Show()

    addon.TrackerFrame = trackerFrame
    addon.AuraButtons = buttons
    addon.WatchButtons = watchButtons
    addon.TrackerEventFrame = trackerEventFrame
    playerGUID = UnitGUID and UnitGUID("player") or nil
    combatStateActive = IsInCombat()
    ProcessExistingHarmfulAuras("player")
    addon:UpdateTrackedAuras("init")
end

function addon:RefreshTrackerLayout()
    if not trackerFrame then
        return
    end

    RefreshTrackerLayout()
    EnsureTrackerOnScreen()
end

function addon:DiagnosticScan()
    apiMethodUsed = nil
    filterMethodUsed = nil
    ProcessExistingHarmfulAuras("player")
    print("|cff00ccffDebuff Tracker|r --- SCAN ---")
    print("  AuraUtil.ForEachAura: " .. (AuraUtil and AuraUtil.ForEachAura and "|cff00ff00EXISTS|r" or "|cffff0000MISSING|r"))
    print("  GetDebuffDataByIndex: " .. (C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex and "|cff00ff00EXISTS|r" or "|cffff0000MISSING|r"))
    print("  GetAuraDataByIndex: " .. (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex and "|cff00ff00EXISTS|r" or "|cffff0000MISSING|r"))
    print("  GetUnitAuraInstanceIDs: " .. (C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs and "|cff00ff00EXISTS|r" or "|cffff0000MISSING|r"))
    print("  GetUnitAuraBySpellID: " .. (C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID and "|cff00ff00EXISTS|r" or "|cffff0000MISSING|r"))
    print("  InCombat: " .. tostring(IsInCombat()))
    print("  Configured Filter: |cffffff00" .. tostring(GetConfiguredAuraFilter()) .. "|r")

    local auras = ScanAllPlayerDebuffs()
    local filteredAuras = ScanPlayerDebuffs()
    local trackedLookup = BuildTrackedLookup()
    local activeInstanceIDs = GetUnitAuraInstanceOrder("player", "HARMFUL", 40) or {}
    local activeInstanceSet = {}
    for _, auraInstanceID in ipairs(activeInstanceIDs) do
        activeInstanceSet[auraInstanceID] = true
    end
    print("  Method: |cffffff00" .. tostring(apiMethodUsed) .. "|r")
    print("  Filter Method: |cffffff00" .. tostring(filterMethodUsed) .. "|r")
    print("  AuraInfo: |cffffff00" .. tostring(auraOrder.player and #auraOrder.player or 0) .. "|r")
    print("  Active Instances: |cffffff00" .. tostring(#activeInstanceIDs) .. "|r")
    print("  Debuffs found: |cffffff00" .. #auras .. "|r")
    print("  Filtered shown: |cffffff00" .. #filteredAuras .. "|r")
    print("  Tracked selected: |cffffff00" .. tostring(#trackedLookup.spells) .. "|r")
    if trackedLookup.hasAny then
        for _, spellInfo in ipairs(trackedLookup.spells) do
            print("  Track " .. tostring(spellInfo.spellId)
                .. ": " .. tostring(spellInfo.spellName or "unknown"))
            local rawSpellAura = GetTrackedAuraBySpellIDRaw("player", spellInfo.spellId)
            local debugCall = DebugGetUnitAuraBySpellIDCall("player", spellInfo.spellId)
            print("    BySpellIDRaw " .. tostring(spellInfo.spellId) .. ": " .. FormatAuraDataAsJson(rawSpellAura))
            print("    BySpellIDCall " .. tostring(spellInfo.spellId)
                .. ": ok=" .. tostring(debugCall.ok)
                .. " resultType=" .. tostring(debugCall.resultType)
                .. " error=" .. tostring(debugCall.error))
            for _, aura in ipairs(auras) do
                if aura and aura.auraIndex then
                    local tooltipSpellId = GetTooltipSpellIDByAuraIndex(aura.auraIndex, aura.queryFilter)
                    local ok, matched = pcall(function()
                        return tooltipSpellId ~= nil and tooltipSpellId == spellInfo.spellId
                    end)
                    if ok and matched then
                        print("    TooltipProbe " .. tostring(spellInfo.spellId)
                            .. ": HIT index=" .. tostring(aura.auraIndex)
                            .. " instance=" .. tostring(aura.auraInstanceID or "nil"))
                    end
                end
            end
        end
    else
        print("  Track: no tracked spells selected")
    end
    for i, aura in ipairs(auras) do
        local tooltipDebug = aura and aura.auraIndex and GetTooltipAuraDebugByAuraIndex(aura.auraIndex, aura.queryFilter) or nil
        print("    " .. i .. ") " .. tostring(aura.name or "?")
            .. " [ID:" .. tostring(aura.spellId or 0)
            .. " instance:" .. tostring(aura.auraInstanceID or "nil")
            .. " icon:" .. tostring(aura.icon or "nil")
            .. " type:" .. tostring(aura.dispelName or "none")
            .. " dur:" .. tostring(aura.duration or 0) .. "]")
        if tooltipDebug then
            print("      TooltipRaw index=" .. tostring(aura.auraIndex or "nil")
                .. " spellId=" .. FormatDiagnosticValue(tooltipDebug.spellId)
                .. " spellName=" .. FormatDiagnosticValue(tooltipDebug.spellName)
                .. " dataId=" .. FormatDiagnosticValue(tooltipDebug.dataId))
        end
    end

    local firstButton = buttons[1]
    if firstButton then
        print("  Button1: shown=" .. tostring(firstButton:IsShown())
            .. " spell=" .. tostring(firstButton.spellId)
            .. " icon=" .. tostring(firstButton.currentIcon))
    end

    print("|cff00ccffDebuff Tracker|r --- END ---")
end

function addon:DiagnosticCache()
    ProcessExistingHarmfulAuras("player")

    local trackedLookup = BuildTrackedLookup()
    print("|cff00ccffDebuff Tracker|r --- CACHE ---")
    print("  InCombat: " .. tostring(IsInCombat()))
    print("  AuraInfo: |cffffff00" .. tostring(auraOrder.player and #auraOrder.player or 0) .. "|r")
    print("  Tracked selected: |cffffff00" .. tostring(#trackedLookup.spells) .. "|r")

    if trackedLookup.hasAny then
        for _, spellInfo in ipairs(trackedLookup.spells) do
            print("  Track " .. tostring(spellInfo.spellId)
                .. ": " .. tostring(spellInfo.spellName or "unknown"))
        end
    else
        print("  Track: no tracked spells selected")
    end

    for i, auraInstanceID in ipairs(auraOrder.player or {}) do
        local aura = auraFiltered.HARMFUL.player and auraFiltered.HARMFUL.player[auraInstanceID]
        local spellId = GetAccessibleAuraValue(aura and aura.spellId)
        local auraName = GetAccessibleAuraValue(aura and aura.name)
        local auraInstanceID = GetAccessibleAuraValue(aura and aura.auraInstanceID)
        local auraIndex = GetAccessibleAuraValue(aura and aura.auraIndex)
        local icon = GetAccessibleAuraValue(aura and aura.icon)
        local trackedById = SafeTrackedLookup(trackedLookup.spellIds, aura and aura.spellId)
        local trackedByName = SafeTrackedLookup(trackedLookup.spellNames, aura and aura.name)

        print("  " .. tostring(i)
            .. ") key=instance:" .. tostring(auraInstanceID or "nil")
            .. " instance=" .. FormatDiagnosticValue(auraInstanceID)
            .. " index=" .. FormatDiagnosticValue(auraIndex)
            .. " spell=" .. FormatDiagnosticValue(aura and aura.spellId)
            .. " name=" .. FormatDiagnosticValue(aura and aura.name)
            .. " icon=" .. FormatDiagnosticValue(icon)
            .. " canSpell=" .. tostring(CanAccessValue(aura and aura.spellId))
            .. " canName=" .. tostring(CanAccessValue(aura and aura.name))
            .. " trackedId=" .. tostring(trackedById)
            .. " trackedName=" .. tostring(trackedByName))
    end

    print("|cff00ccffDebuff Tracker|r --- END ---")
end

function addon:SaveTrackerPosition()
    if not trackerFrame then
        return
    end

    local point, _, relPoint, x, y = trackerFrame:GetPoint()
    addon.db.framePosition = {
        point = point,
        relativePoint = relPoint,
        x = x,
        y = y,
    }
end

function addon:ResetTrackerPosition()
    if not trackerFrame then
        return
    end

    trackerFrame:ClearAllPoints()
    trackerFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    if trackerFrame.SetClampedToScreen then
        trackerFrame:SetClampedToScreen(true)
    end
    addon:SaveTrackerPosition()
end

function addon:UpdateTrackerLock()
    UpdateAnchorVisibility()
end
