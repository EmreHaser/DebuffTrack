local addonName, addon = ...

local trackerFrame = nil
local coTankContainer = nil
local tickFrame = nil
local scanTooltip = nil
local layoutEditorFrame = nil
local buttons = {}
local watchButtons = {}
local coTankFrames = {}
local trackerEventFrame = CreateFrame("Frame")
local auraDispelColorCurve = nil

local MAX_ICONS = 10
local COTANK_MAX_ICONS = 6
local ICON_SIZE = 36
local ICON_SPACING = 4
local ANCHOR_ICON_COUNT = 4
local TRACKER_NORMAL_STRATA = "TOOLTIP"
local TRACKER_EDITOR_STRATA = "MEDIUM"
local EDIT_PREVIEW_ICONS = { 132345, 136033, 463281 }
local WATCH_ROW_GAP = 10
local COTANK_SECTION_GAP = 10
local COTANK_FRAME_GAP = 8
local COTANK_BAR_STYLE = {
    defaultHeight = 44,
    border = 2,
    iconGap = 6,
    textInset = 12,
    minWidth = 252,
}
local AURA_MIN_DISPLAY_COUNT = 2
local AURA_MAX_DISPLAY_COUNT = 99
local DEFAULT_AURA_FILTER = "IMPORTANT"
local RAW_AURA_FILTER = "HARMFUL"
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
local activeCoTankCount = 0
local lastDebugSnapshot = nil
local lastCombatSnapshot = nil
local combatStateActive = false
local playerGUID = nil
local coTankUnits = {}
local coTankDragActive = false
local runtimeUiHelpers = {}
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
local ScanAllUnitDebuffs
local ScanUnitDebuffs
local ApplyCoTankFrameLayout
local ApplyCoTankContainerPosition
local RefreshCoTankFrames
local GetCoTankFrameByUnit
local UpdateCoTankHealthDisplay
local UpdateTrackerHeight

local function IsUnitPlayer(unit)
    if not unit then
        return false
    end

    if UnitIsUnit then
        local ok, sameUnit = pcall(UnitIsUnit, unit, "player")
        if ok then
            return sameUnit == true
        end
    end

    if UnitGUID then
        local unitGuid = UnitGUID(unit)
        if unitGuid and playerGUID then
            return unitGuid == playerGUID
        end
    end

    return unit == "player"
end

local function GetUnitDisplayName(unit)
    if not unit then
        return ""
    end

    if GetUnitName then
        local ok, value = pcall(GetUnitName, unit, true)
        if ok and value and value ~= "" then
            return value
        end
    end

    if UnitName then
        local ok, value = pcall(UnitName, unit)
        if ok and value and value ~= "" then
            return value
        end
    end

    return tostring(unit)
end

local function GetRaidTankUnits()
    local units = {}
    local includePlayer = addon and addon.db and addon.db.coTankShowPlayer == true

    if not IsInRaid or not IsInRaid() then
        return units
    end

    for i = 1, 40 do
        local unit = "raid" .. i
        if UnitExists and UnitExists(unit)
            and UnitGroupRolesAssigned
            and UnitGroupRolesAssigned(unit) == "TANK"
            and (includePlayer or not IsUnitPlayer(unit))
        then
            units[#units + 1] = unit
        end
    end

    table.sort(units, function(left, right)
        local leftName = GetUnitDisplayName(left)
        local rightName = GetUnitDisplayName(right)
        if leftName == rightName then
            return left < right
        end
        return leftName < rightName
    end)

    return units
end

local function IsTrackedCoTankUnit(unit)
    if not unit then
        return false
    end

    for _, trackedUnit in ipairs(coTankUnits) do
        if trackedUnit == unit then
            return true
        end
    end

    return false
end

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

local function GetLayoutTargetKey(targetKey)
    return targetKey == "cotank" and "cotank" or "tracker"
end

local function GetAuraFilterDbKey(targetKey)
    return GetLayoutTargetKey(targetKey) == "cotank" and "coTankAuraFilter" or "auraFilter"
end

local function GetLayoutDbKey(targetKey)
    return GetLayoutTargetKey(targetKey) == "cotank" and "coTankLayout" or "layout"
end

local function GetBorderModeDbKey(targetKey)
    return GetLayoutTargetKey(targetKey) == "cotank" and "coTankBorderMode" or "borderMode"
end

local function GetBorderColorDbKey(targetKey)
    return GetLayoutTargetKey(targetKey) == "cotank" and "coTankCustomBorderColor" or "customBorderColor"
end

local function GetConfiguredAuraFilter(targetKey)
    local filterKey = GetAuraFilterDbKey(targetKey)
    local configuredFilter = addon and addon.db and addon.db[filterKey] or nil
    if type(configuredFilter) == "table" then
        local filters = {}
        local seen = {}
        for _, token in ipairs(configuredFilter) do
            token = type(token) == "string" and strtrim(string.upper(token)) or nil
            if token and token ~= "" and not seen[token] then
                seen[token] = true
                filters[#filters + 1] = token
            end
        end
        if #filters > 0 then
            return table.concat(filters, "|")
        end
    end

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

local function NormalizeAuraFilterString(auraFilter)
    if type(auraFilter) ~= "string" then
        return ""
    end

    local tokens = {}
    local seen = {}
    for token in string.gmatch(string.upper(auraFilter), "[A-Z_]+") do
        if not seen[token] then
            seen[token] = true
            tokens[#tokens + 1] = token
        end
    end

    return table.concat(tokens, "|")
end

local function AuraMatchesConfiguredFilter(aura, auraFilter, unit)
    if not aura then
        filterMethodUsed = filterMethodUsed or "RawHARMFUL.NoAura"
        return false
    end

    unit = unit or "player"

    local normalizedFilter = NormalizeAuraFilterString(auraFilter)
    if normalizedFilter == "" or normalizedFilter == RAW_AURA_FILTER then
        filterMethodUsed = filterMethodUsed or "RawHARMFUL"
        return true
    end

    if string.find(normalizedFilter, "HELPFUL", 1, true) ~= nil then
        filterMethodUsed = filterMethodUsed or "RawHARMFUL.NoHelpful"
        return false
    end

    if C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID and aura.auraInstanceID ~= nil then
        local ok, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, aura.auraInstanceID, normalizedFilter)
        if ok then
            filterMethodUsed = filterMethodUsed or "IsAuraFilteredOutByInstanceID"
            return not filteredOut
        end
    end

    filterMethodUsed = filterMethodUsed or "RawHARMFUL.Fallback"
    return true
end

local function GetConfiguredCustomBorderColor(targetKey)
    local colorKey = GetBorderColorDbKey(targetKey)
    local color = addon and addon.db and addon.db[colorKey] or nil
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

local function CloneBorderColor(color)
    color = type(color) == "table" and color or {}
    return {
        r = tonumber(color.r) or 0,
        g = tonumber(color.g) or 0,
        b = tonumber(color.b) or 0,
    }
end

local function GetDefaultLayoutSettings(targetKey)
    if GetLayoutTargetKey(targetKey) == "cotank" then
        return {
            iconWidth = 30,
            iconHeight = 30,
            frameWidth = 252,
            barHeight = 44,
            barTextFontSize = 16,
            borderThickness = 2,
            countOffsetX = 10,
            countOffsetY = -8,
            countFontSize = 16,
            durationOffsetX = 0,
            durationOffsetY = -22,
            durationFontSize = 14,
            barFillColor = { r = 0.08, g = 0.93, b = 0.62 },
            barBackgroundColor = { r = 0.04, g = 0.16, b = 0.11 },
        }
    end

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

local function CloneLayoutSettings(layout, targetKey)
    local defaults = GetDefaultLayoutSettings(targetKey)
    layout = type(layout) == "table" and layout or {}
    local legacyScale = tonumber(layout.scale) or 1

    local clone = {
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

    if GetLayoutTargetKey(targetKey) == "cotank" then
        clone.frameWidth = tonumber(layout.frameWidth) or defaults.frameWidth
        clone.barHeight = tonumber(layout.barHeight) or defaults.barHeight
        clone.barTextFontSize = tonumber(layout.barTextFontSize) or defaults.barTextFontSize
        clone.barFillColor = CloneBorderColor(layout.barFillColor or defaults.barFillColor)
        clone.barBackgroundColor = CloneBorderColor(layout.barBackgroundColor or defaults.barBackgroundColor)
    end

    return clone
end

local function GetConfiguredLayoutSettings(targetKey)
    if not addon or not addon.db then
        return GetDefaultLayoutSettings(targetKey)
    end

    local layoutKey = GetLayoutDbKey(targetKey)
    addon.db[layoutKey] = CloneLayoutSettings(addon.db[layoutKey], targetKey)
    return addon.db[layoutKey]
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

local function ClampCoTankFrameWidth(value)
    value = tonumber(value) or COTANK_BAR_STYLE.minWidth
    if value < 120 then
        return 120
    end
    if value > 360 then
        return 360
    end
    return math.floor(value + 0.5)
end

local function ClampCoTankBarHeight(value)
    value = tonumber(value) or COTANK_BAR_STYLE.defaultHeight
    if value < 28 then
        return 28
    end
    if value > 80 then
        return 80
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

local function GetBaseTrackerHeight(layout, watchCount)
    local metrics = GetLayoutMetrics(layout)
    if watchCount and watchCount > 0 then
        return metrics.trackerHeight
    end

    return metrics.mainRowHeight
end

local function GetCoTankFrameMetrics(layout)
    local trackerMetrics = GetLayoutMetrics(layout)
    local minimumWidth = (COTANK_MAX_ICONS * trackerMetrics.iconWidth) + ((COTANK_MAX_ICONS - 1) * ICON_SPACING)
    local barWidth = ClampCoTankFrameWidth(layout and layout.frameWidth)
    local frameWidth = math.max(minimumWidth, barWidth)
    local barHeight = ClampCoTankBarHeight(layout and layout.barHeight)

    return {
        frameWidth = frameWidth,
        barWidth = barWidth,
        frameHeight = barHeight + COTANK_BAR_STYLE.iconGap + trackerMetrics.mainRowHeight,
        iconRowOffset = barHeight + COTANK_BAR_STYLE.iconGap,
        barHeight = barHeight,
    }
end

local function IsCoTankFrameEnabled()
    return not addon or not addon.db or addon.db.coTankEnabled ~= false
end

local function GetDefaultCoTankPosition()
    return {
        point = "TOPLEFT",
        relativePoint = "BOTTOMLEFT",
        x = 0,
        y = -10,
    }
end

local function GetPointOffset(point, width, height)
    local normalizedPoint = tostring(point or "CENTER"):upper()
    local horizontal = 0.5
    local vertical = 0.5

    if normalizedPoint:find("LEFT", 1, true) then
        horizontal = 0
    elseif normalizedPoint:find("RIGHT", 1, true) then
        horizontal = 1
    end

    if normalizedPoint:find("TOP", 1, true) then
        vertical = 1
    elseif normalizedPoint:find("BOTTOM", 1, true) then
        vertical = 0
    end

    return (width or 0) * horizontal, (height or 0) * vertical
end

local function GetUiParentAnchorCoordinates(point)
    local parentWidth = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 0
    local parentHeight = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 0
    return GetPointOffset(point, parentWidth, parentHeight)
end

local function GetAnchorCoordinatesForRect(point, left, bottom, width, height)
    local pointOffsetX, pointOffsetY = GetPointOffset(point, width, height)
    return (left or 0) + pointOffsetX, (bottom or 0) + pointOffsetY
end

local function GetRectFromAnchor(point, anchorX, anchorY, width, height)
    local pointOffsetX, pointOffsetY = GetPointOffset(point, width, height)
    return (anchorX or 0) - pointOffsetX, (anchorY or 0) - pointOffsetY
end

local function GetTrackerRect()
    if not trackerFrame then
        return nil
    end

    local width = trackerFrame.GetWidth and trackerFrame:GetWidth() or 0
    local height = trackerFrame.GetHeight and trackerFrame:GetHeight() or 0
    local point, _, relativePoint, x, y = trackerFrame:GetPoint()
    local anchorX, anchorY = GetUiParentAnchorCoordinates(relativePoint or "CENTER")
    local left, bottom = GetRectFromAnchor(point or "CENTER", anchorX + (x or 0), anchorY + (y or 0), width, height)
    return left, bottom, width, height
end

local function ConvertLegacyCoTankPosition(savedPosition)
    local source = savedPosition or GetDefaultCoTankPosition()
    local trackerLeft, trackerBottom, trackerWidth, trackerHeight = GetTrackerRect()
    if trackerLeft == nil then
        return {
            point = source.point or "TOPLEFT",
            relativePoint = source.point or "TOPLEFT",
            x = source.x or 0,
            y = source.y or 0,
            relativeTo = "UIParent",
        }
    end

    local desiredAnchorX, desiredAnchorY = GetAnchorCoordinatesForRect(
        source.relativePoint or "BOTTOMLEFT",
        trackerLeft,
        trackerBottom,
        trackerWidth or 0,
        trackerHeight or 0
    )
    desiredAnchorX = desiredAnchorX + (source.x or 0)
    desiredAnchorY = desiredAnchorY + (source.y or 0)

    local point = source.point or "TOPLEFT"
    local uiParentAnchorX, uiParentAnchorY = GetUiParentAnchorCoordinates(point)
    return {
        point = point,
        relativePoint = point,
        x = desiredAnchorX - uiParentAnchorX,
        y = desiredAnchorY - uiParentAnchorY,
        relativeTo = "UIParent",
    }
end

local function GetNormalizedCoTankPosition()
    local savedPosition = addon and addon.db and addon.db.coTankFramePosition or nil
    if savedPosition and savedPosition.relativeTo == "UIParent" then
        return savedPosition
    end

    local normalized = ConvertLegacyCoTankPosition(savedPosition)
    if addon and addon.db then
        addon.db.coTankFramePosition = CopyTable(normalized)
    end
    return normalized
end

local function TryUnitMetric(unit, reader, ...)
    if not unit or not reader then
        return nil
    end

    local ok, value = pcall(reader, unit, ...)
    if ok then
        return value
    end

    return nil
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

    scanTooltip = CreateFrame("GameTooltip", "DebuffTrackScanTooltip", UIParent, "GameTooltipTemplate")
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

local function GetTooltipSpellIDByAuraIndex(unit, index, auraFilter)
    local tooltip = EnsureScanTooltip()
    if not tooltip then
        return nil
    end

    unit = unit or "player"

    if tooltip.ClearLines then
        tooltip:ClearLines()
    end
    if not SetTooltipAuraByIndex(tooltip, unit, index, auraFilter) then
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

local function GetTooltipAuraDebugByAuraIndex(unit, index, auraFilter)
    local tooltip = EnsureScanTooltip()
    if not tooltip then
        return {
            spellId = nil,
            spellName = nil,
            dataId = nil,
        }
    end

    unit = unit or "player"

    if tooltip.ClearLines then
        tooltip:ClearLines()
    end
    if not SetTooltipAuraByIndex(tooltip, unit, index, auraFilter) then
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

local function ShouldHideRawAura(unit, aura)
    if unit ~= "player" or not aura or not aura.auraIndex or not IsPlayerMonk() then
        return false
    end

    local tooltipDebug = GetTooltipAuraDebugByAuraIndex(unit, aura.auraIndex, aura.queryFilter)
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

local function ResolveFullAuraData(aura, unit)
    if not aura then
        return nil
    end

    unit = unit or "player"

    if aura.auraInstanceID
        and C_UnitAuras
        and C_UnitAuras.GetAuraDataByAuraInstanceID
        and (aura.spellId == nil or aura.icon == nil or aura.name == nil or aura.duration == nil)
    then
        local fullAura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aura.auraInstanceID)
        if fullAura then
            return fullAura
        end
    end

    return aura
end

local function NormalizeAura(aura, unit)
    if not aura then
        return nil
    end

    aura = ResolveFullAuraData(aura, unit)

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

local function GetUnitAuraByIndex(unit, index)
    unit = unit or "player"

    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        apiMethodUsed = apiMethodUsed or "GetDebuffDataByIndex"
        return SetAuraQueryFilter(NormalizeAura(C_UnitAuras.GetDebuffDataByIndex(unit, index), unit), RAW_AURA_FILTER)
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        apiMethodUsed = apiMethodUsed or "GetAuraDataByIndex"
        return SetAuraQueryFilter(NormalizeAura(C_UnitAuras.GetAuraDataByIndex(unit, index, RAW_AURA_FILTER), unit), RAW_AURA_FILTER)
    end

    if UnitAura then
        apiMethodUsed = apiMethodUsed or "UnitAura"
        local name, icon, applications, dispelType, duration, expirationTime, _, _, _, spellId = UnitAura(unit, index, RAW_AURA_FILTER)
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
        }, RAW_AURA_FILTER)
    end

    return nil
end

GetAuraByIndex = function(index)
    return GetUnitAuraByIndex("player", index)
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

local function ShouldSkipAuraFilter(unit, aura, filter)
    if not aura then
        return true
    end

    if filter == "HARMFUL" then
        return not AuraIsHarmful(unit, aura)
    end

    return true
end

local function StoreAuraState(unit, aura)
    local normalized = NormalizeAura(aura, unit)
    if not normalized or not normalized.auraInstanceID then
        return
    end

    EnsureAuraState(unit)

    if AuraIsHarmful(unit, normalized) then
        normalized.auraIsHarmful = true
    end

    auraInfo[unit][normalized.auraInstanceID] = normalized
    auraFiltered.HARMFUL[unit][normalized.auraInstanceID] =
        not ShouldSkipAuraFilter(unit, normalized, "HARMFUL") and normalized or nil
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

    local rawAuras = ScanAllUnitDebuffs(unit, 40)
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
                    aura = NormalizeAura(auraData, unit)
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
    local rawAuras = ScanAllUnitDebuffs(unit, 40)
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
    local rawAuras = ScanAllUnitDebuffs(unit, 40)

    for _, aura in ipairs(rawAuras) do
        if aura and aura.auraIndex then
            local tooltipDebug = GetTooltipAuraDebugByAuraIndex(unit, aura.auraIndex, aura.queryFilter)
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

ScanAllUnitDebuffs = function(unit, maxCount)
    unit = unit or "player"
    local result = {}

    for i = 1, 40 do
        local aura = GetUnitAuraByIndex(unit, i)
        if not aura then
            break
        end
        aura.auraIndex = aura.auraIndex or i
        if not ShouldHideRawAura(unit, aura) then
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
        AuraUtil.ForEachAura(unit, RAW_AURA_FILTER, 40, function(aura)
            local normalized = SetAuraQueryFilter(NormalizeAura(aura, unit), RAW_AURA_FILTER)
            if normalized then
                result[#result + 1] = normalized
            end
            return maxCount and #result >= maxCount or false
        end, true)
    end

    return result
end

ScanAllPlayerDebuffs = function(maxCount)
    return ScanAllUnitDebuffs("player", maxCount)
end

local function GetFilterAuraByIndex(index, targetKey)
    local auraFilter = GetConfiguredAuraFilter(targetKey)

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

local function ScanFilterablePlayerDebuffs(targetKey)
    local result = {}

    for i = 1, 40 do
        local aura = GetFilterAuraByIndex(i, targetKey)
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

ScanUnitDebuffs = function(unit, maxCount, targetKey)
    unit = unit or "player"

    local configuredFilter = GetConfiguredAuraFilter(targetKey)
    local result = {}
    local rawAuras = ScanAllUnitDebuffs(unit, 40)
    local iconLimit = maxCount or MAX_ICONS

    filterMethodUsed = nil
    for _, aura in ipairs(rawAuras) do
        if AuraMatchesConfiguredFilter(aura, configuredFilter, unit) then
            result[#result + 1] = aura
            if #result >= iconLimit then
                break
            end
        end
    end

    filterMethodUsed = filterMethodUsed or "RawHARMFUL.NoMatch"
    return result
end

local function ScanPlayerDebuffs()
    return ScanUnitDebuffs("player", MAX_ICONS, "tracker")
end

local function GetBorderColor(aura, unit, targetKey)
    unit = unit or "player"

    local borderModeKey = GetBorderModeDbKey(targetKey)
    local borderMode = addon and addon.db and addon.db[borderModeKey] or "blizzard"
    if borderMode == "blizzard" then
        local curve = EnsureAuraDispelColorCurve()
        if aura and aura.auraInstanceID and curve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
            local ok, colorOrR, g, b = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, aura.auraInstanceID, curve)
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

    return GetConfiguredCustomBorderColor(targetKey)
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

    if coTankContainer then
        local coTankMetrics = GetCoTankFrameMetrics(GetConfiguredLayoutSettings("cotank"))
        coTankContainer:SetWidth(coTankMetrics.frameWidth)
    end
end

local function RefreshTrackerLayout()
    local layout = GetConfiguredLayoutSettings()
    local coTankLayout = GetConfiguredLayoutSettings("cotank")

    ApplyTrackerGeometry(layout)

    for i = 1, MAX_ICONS do
        ApplyTextLayoutToButton(buttons[i], layout)
        ApplyBorderThickness(watchButtons[i], layout.borderThickness)
    end

    for index, frame in ipairs(coTankFrames) do
        if frame then
            ApplyCoTankFrameLayout(frame, index, coTankLayout)
        end
    end

    RefreshCoTankFrames()
    UpdateTrackerHeight(0)
end

local function UpdateAnchorVisibility()
    if not trackerFrame or not trackerFrame.anchor then
        return
    end

    local showAnchor = addon.editModeActive == true

    if showAnchor then
        trackerFrame.anchor:Show()
        if coTankContainer and coTankContainer.anchor then
            coTankContainer.anchor:Show()
        end
    else
        trackerFrame.anchor:Hide()
        if coTankContainer and coTankContainer.anchor then
            coTankContainer.anchor:Hide()
        end
    end
end

local function UpdateTrackerStrata()
    if not trackerFrame or not trackerFrame.SetFrameStrata then
        return
    end

    local editorOpen = layoutEditorFrame and layoutEditorFrame.IsShown and layoutEditorFrame:IsShown()
    local strata = editorOpen and TRACKER_EDITOR_STRATA or TRACKER_NORMAL_STRATA
    trackerFrame:SetFrameStrata(strata)

    local function ApplyStrata(frame)
        if frame and frame.SetFrameStrata then
            frame:SetFrameStrata(strata)
        end
    end

    ApplyStrata(trackerFrame.anchor)
    ApplyStrata(trackerFrame.editOverlay)
    ApplyStrata(coTankContainer)
    ApplyStrata(coTankContainer and coTankContainer.anchor or nil)
    ApplyStrata(coTankContainer and coTankContainer.editOverlay or nil)

    for _, button in ipairs(buttons) do
        ApplyStrata(button)
    end
    for _, button in ipairs(watchButtons) do
        ApplyStrata(button)
    end
    for _, frame in ipairs(coTankFrames) do
        ApplyStrata(frame)
        if frame and frame.auraButtons then
            for _, button in ipairs(frame.auraButtons) do
                ApplyStrata(button)
            end
        end
    end
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
    button.ownerUnit = nil

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

UpdateTrackerHeight = function(watchCount)
    if not trackerFrame then
        return
    end

    local layout = GetConfiguredLayoutSettings()
    local baseHeight = GetBaseTrackerHeight(layout, watchCount)
    trackerFrame:SetHeight(baseHeight)

    if coTankContainer then
        if IsInCombat() then
            addon._pendingCoTankFullRefresh = true
        else
            local coTankLayout = GetConfiguredLayoutSettings("cotank")
            local coTankMetrics = GetCoTankFrameMetrics(coTankLayout)
            ApplyCoTankContainerPosition()
            coTankContainer:SetWidth(coTankMetrics.frameWidth)
        end
    end
end

local function RefreshWatchButtons()
    for i = 1, MAX_ICONS do
        ClearWatchButton(watchButtons[i])
    end

    return 0
end

local function ApplyAuraToButton(button, aura, unit, targetKey)
    if not button then
        return
    end

    unit = unit or button.ownerUnit or "player"

    if not aura then
        ClearButton(button)
        return
    end

    local texID = aura.icon
    local queryFilter = aura.queryFilter
    if texID == nil and aura.auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local fullAura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, aura.auraInstanceID)
        if fullAura then
            local normalized = NormalizeAura(fullAura, unit)
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

    local r, g, b = GetBorderColor(aura, unit, targetKey)
    if button.borderTop then button.borderTop:SetColorTexture(r, g, b, 1) end
    if button.borderBottom then button.borderBottom:SetColorTexture(r, g, b, 1) end
    if button.borderLeft then button.borderLeft:SetColorTexture(r, g, b, 1) end
    if button.borderRight then button.borderRight:SetColorTexture(r, g, b, 1) end

    if button.count then
        local displayCount = nil
        if aura.auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount then
            displayCount = C_UnitAuras.GetAuraApplicationDisplayCount(unit, aura.auraInstanceID, AURA_MIN_DISPLAY_COUNT, AURA_MAX_DISPLAY_COUNT)
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
    button.ownerUnit = unit
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

    ApplyTextLayoutToButton(button, GetConfiguredLayoutSettings(targetKey))
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
        ApplyAuraToButton(buttons[i], auras[i], "player", "tracker")
    end

    local watchCount = RefreshWatchButtons()
    RefreshCoTankFrames()
    UpdateTrackerHeight(watchCount)

    UpdateAnchorVisibility()
    addon:CaptureDebugSnapshot(reason or "manual")
end

local function OnTrackerEvent(_, event, unit, updateInfo)
    local shouldRefreshTracker = false

    if event == "UNIT_AURA" then
        if unit == "player" then
            eventCounters.unitAura = eventCounters.unitAura + 1
            UpdateAuraStateFromInfo("player", updateInfo)
            shouldRefreshTracker = true
        elseif IsTrackedCoTankUnit(unit) then
            shouldRefreshTracker = true
        else
            return
        end
    elseif event == "UNIT_HEALTH"
        or event == "UNIT_MAXHEALTH"
        or event == "UNIT_FLAGS"
        or event == "UNIT_CONNECTION"
        or event == "UNIT_NAME_UPDATE"
    then
        local frame = GetCoTankFrameByUnit(unit)
        if not frame then
            return
        end

        UpdateCoTankHealthDisplay(frame)
        return
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
        shouldRefreshTracker = true
    elseif event == "PLAYER_REGEN_DISABLED" then
        combatStateActive = true
        eventCounters.enterCombat = eventCounters.enterCombat + 1
        shouldRefreshTracker = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        eventCounters.leaveCombat = eventCounters.leaveCombat + 1
        shouldRefreshTracker = true
    elseif event == "PLAYER_ENTERING_WORLD" then
        playerGUID = UnitGUID and UnitGUID("player") or nil
        ProcessExistingHarmfulAuras("player")
        shouldRefreshTracker = true
    end

    if trackerFrame and shouldRefreshTracker then
        addon:UpdateTrackedAuras(event)
    end

    if event == "PLAYER_REGEN_ENABLED" then
        combatStateActive = false
        if trackerFrame and addon._pendingCoTankFullRefresh then
            addon:UpdateTrackedAuras("combat-exit")
        end
    end
end

trackerEventFrame:RegisterEvent("UNIT_AURA")
trackerEventFrame:RegisterEvent("UNIT_HEALTH")
trackerEventFrame:RegisterEvent("UNIT_MAXHEALTH")
trackerEventFrame:RegisterEvent("UNIT_FLAGS")
trackerEventFrame:RegisterEvent("UNIT_CONNECTION")
trackerEventFrame:RegisterEvent("UNIT_NAME_UPDATE")
trackerEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
trackerEventFrame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
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

    for _, frame in ipairs(coTankFrames) do
        if frame and frame.auraButtons then
            for _, button in ipairs(frame.auraButtons) do
                SetButtonVisible(button, button.isActive == true)
            end
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

        local unit = self.ownerUnit or "player"
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if self.auraIndex then
            SetTooltipAuraByIndex(GameTooltip, unit, self.auraIndex, self.queryFilter)
        elseif self.auraInstanceID and GameTooltip.SetUnitDebuffByAuraInstanceID then
            GameTooltip:SetUnitDebuffByAuraInstanceID(unit, self.auraInstanceID)
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

local function EnsureCoTankContainer()
    if coTankContainer or not trackerFrame then
        return coTankContainer
    end

    coTankContainer = CreateFrame("Frame", nil, UIParent)
    coTankContainer:SetSize(1, 1)
    coTankContainer:SetClampedToScreen(true)
    ApplyCoTankContainerPosition(true)
    coTankContainer:Hide()
    return coTankContainer
end

ApplyCoTankContainerPosition = function(force)
    if not coTankContainer then
        return
    end

    if IsInCombat() then
        addon._pendingCoTankFullRefresh = true
        return
    end

    if coTankDragActive and force ~= true then
        return
    end

    local pos = GetNormalizedCoTankPosition()
    coTankContainer:ClearAllPoints()
    coTankContainer:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
end

local function ApplyCoTankBarAppearance(frame, layout, fillR, fillG, fillB)
    if not frame then
        return
    end

    layout = CloneLayoutSettings(layout, "cotank")
    local barR, barG, barB = fillR, fillG, fillB
    if barR == nil or barG == nil or barB == nil then
        local fillColor = CloneBorderColor(layout.barFillColor)
        barR, barG, barB = fillColor.r, fillColor.g, fillColor.b
    end

    local bgColor = CloneBorderColor(layout.barBackgroundColor)
    local bgR, bgG, bgB = bgColor.r, bgColor.g, bgColor.b
    if frame.healthBar and frame.healthBar.SetStatusBarColor then
        frame.healthBar:SetStatusBarColor(barR, barG, barB, 1)
    end
    if frame.healthBarBg then
        frame.healthBarBg:SetColorTexture(bgR, bgG, bgB, 0.95)
    end

    local fontSize = ClampFontSize(layout.barTextFontSize or 16)
    if frame.nameText and frame.nameText.SetFont and STANDARD_TEXT_FONT then
        frame.nameText:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
    end
    if frame.healthText and frame.healthText.SetFont and STANDARD_TEXT_FONT then
        frame.healthText:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
    end
end

runtimeUiHelpers.GetUnitClassTag = function(unit)
    if not unit then
        return nil
    end

    if UnitClassBase then
        local ok, classTag = pcall(UnitClassBase, unit)
        if ok and classTag and classTag ~= "" then
            return classTag
        end
    end

    if UnitClass then
        local ok, _, classTag = pcall(UnitClass, unit)
        if ok and classTag and classTag ~= "" then
            return classTag
        end
    end

    return nil
end

runtimeUiHelpers.GetUnitClassColor = function(unit)
    local classTag = runtimeUiHelpers.GetUnitClassTag(unit)
    if not classTag then
        return nil
    end

    if CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[classTag] then
        local color = CUSTOM_CLASS_COLORS[classTag]
        return color.r or 1, color.g or 1, color.b or 1
    end

    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classTag] then
        local color = RAID_CLASS_COLORS[classTag]
        return color.r or 1, color.g or 1, color.b or 1
    end

    if C_ClassColor and C_ClassColor.GetClassColor then
        local color = C_ClassColor.GetClassColor(classTag)
        if color then
            if color.GetRGB then
                return color:GetRGB()
            end
            return color.r or 1, color.g or 1, color.b or 1
        end
    end

    return nil
end

runtimeUiHelpers.TryFormatCoTankPercentWithStatusBar = function(frame, rawHealthValue)
    if not frame or not frame.healthBar or not frame.healthBar.GetStatusBarTexture then
        return nil
    end

    local healthBar = frame.healthBar
    local statusBarTexture = healthBar:GetStatusBarTexture()
    if not statusBarTexture or not statusBarTexture.GetWidth or not healthBar.GetWidth then
        return nil
    end

    local totalWidth = runtimeUiHelpers.CoerceDisplayNumber(healthBar:GetWidth())
    local fillWidth = runtimeUiHelpers.CoerceDisplayNumber(statusBarTexture:GetWidth())
    if type(totalWidth) ~= "number" or totalWidth <= 0 or type(fillWidth) ~= "number" then
        return nil
    end

    if fillWidth <= 0 and not CanAccessValue(rawHealthValue) then
        return nil
    end

    local percent = fillWidth / totalWidth
    if percent < 0 then
        percent = 0
    elseif percent > 1 then
        percent = 1
    end

    return string.format("%d%%", math.floor((percent * 100) + 0.5))
end

runtimeUiHelpers.MarkLayoutEditorDirty = function()
    if layoutEditorFrame then
        layoutEditorFrame.hasPendingChanges = true
        layoutEditorFrame.discardChangesOnHide = false
    end
end

runtimeUiHelpers.CoerceDisplayNumber = function(value)
    if value == nil or not CanAccessValue(value) then
        return nil
    end

    local ok, normalized = pcall(function()
        return tonumber(tostring(value))
    end)
    if ok then
        return normalized
    end
    return nil
end

runtimeUiHelpers.GetCurveConstant = function(curveName)
    if type(CurveConstants) ~= "table" or not curveName then
        return nil
    end

    return CurveConstants[curveName]
end

runtimeUiHelpers.GetUnitHealthPercentValue = function(unit, curve)
    if not unit or not UnitHealthPercent then
        return nil
    end

    if curve ~= nil then
        local ok, value = pcall(UnitHealthPercent, unit, false, curve)
        if ok then
            return value
        end
    end

    do
        local ok, value = pcall(UnitHealthPercent, unit, false)
        if ok then
            return value
        end
    end

    do
        local ok, value = pcall(UnitHealthPercent, unit)
        if ok then
            return value
        end
    end

    return nil
end

runtimeUiHelpers.ApplyCoTankPercentText = function(fontString, unit)
    if not fontString or not unit then
        return false
    end

    local percentValue = runtimeUiHelpers.GetUnitHealthPercentValue(unit, runtimeUiHelpers.GetCurveConstant("ScaleTo100"))
    if percentValue == nil then
        percentValue = runtimeUiHelpers.GetUnitHealthPercentValue(unit)
    end

    if percentValue == nil then
        return false
    end

    if fontString.SetFormattedText then
        local ok = pcall(fontString.SetFormattedText, fontString, "%0.f%%", percentValue)
        if ok then
            return true
        end

        ok = pcall(fontString.SetFormattedText, fontString, "%s%%", percentValue)
        if ok then
            return true
        end
    end

    local accessiblePercent = runtimeUiHelpers.CoerceDisplayNumber(percentValue)
    if accessiblePercent == nil then
        return false
    end

    fontString:SetText(string.format("%d%%", math.floor(accessiblePercent + 0.5)))
    return true
end

UpdateCoTankHealthDisplay = function(frame)
    if not frame or not frame.unit then
        return
    end

    local unit = frame.unit
    local layout = GetConfiguredLayoutSettings("cotank")
    local healthCurrent = TryUnitMetric(unit, UnitHealth)
    local healthMax = TryUnitMetric(unit, UnitHealthMax)
    local isDead = UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit) or false
    local isConnected = UnitIsConnected == nil or UnitIsConnected(unit)
    local healthPercent = runtimeUiHelpers.GetUnitHealthPercentValue(unit, runtimeUiHelpers.GetCurveConstant("ZeroToOne"))
    local healthPercentText = nil
    local healthTextWasApplied = false
    local classR, classG, classB = runtimeUiHelpers.GetUnitClassColor(unit)
    local fillColor = CloneBorderColor(layout.barFillColor)
    local barR, barG, barB = classR or fillColor.r, classG or fillColor.g, classB or fillColor.b

    if not isConnected then
        barR, barG, barB = 0.28, 0.30, 0.34
    elseif isDead then
        barR, barG, barB = 0.55, 0.14, 0.14
    end

    if frame.nameText then
        frame.nameText:SetText(GetUnitDisplayName(unit))
    end

    if frame.healthBar then
        if frame.healthBar.SetMinMaxValues then
            local ok = pcall(frame.healthBar.SetMinMaxValues, frame.healthBar, 0, 1)
            if not ok then
                frame.healthBar:SetMinMaxValues(0, 1)
            end
        end
        if frame.healthBar.SetValue then
            local displayValue = healthPercent
            if not isConnected or isDead then
                displayValue = 0
            elseif displayValue == nil then
                local currentValue = runtimeUiHelpers.CoerceDisplayNumber(healthCurrent)
                local maxValue = runtimeUiHelpers.CoerceDisplayNumber(healthMax)
                if type(currentValue) == "number" and type(maxValue) == "number" and maxValue > 0 then
                    displayValue = currentValue / maxValue
                end
            end

            if displayValue ~= nil and CanAccessValue(displayValue) then
                local accessibleValue = runtimeUiHelpers.CoerceDisplayNumber(displayValue)
                if accessibleValue ~= nil then
                    if accessibleValue < 0 then
                        accessibleValue = 0
                    elseif accessibleValue > 1 then
                        if accessibleValue <= 100 then
                            accessibleValue = accessibleValue / 100
                        else
                            accessibleValue = 1
                        end
                    end

                    displayValue = accessibleValue
                end
            end

            if displayValue == nil then
                displayValue = 0
            end

            local ok = pcall(frame.healthBar.SetValue, frame.healthBar, displayValue)
            if not ok then
                frame.healthBar:SetValue(0)
            end
        end
    end

    if isConnected and not isDead and frame.healthText then
        healthTextWasApplied = runtimeUiHelpers.ApplyCoTankPercentText(frame.healthText, unit)
    end

    if not healthTextWasApplied then
        healthPercentText = runtimeUiHelpers.TryFormatCoTankPercentWithStatusBar(frame, healthCurrent)
    end

    if not healthTextWasApplied and not healthPercentText then
        local displayHealth = healthPercent
        local displayMax = healthPercent ~= nil and 1 or nil
        if displayHealth == nil and frame.healthBar and frame.healthBar.GetStatusBarTexture and frame.healthBar.GetWidth then
            healthPercentText = runtimeUiHelpers.TryFormatCoTankPercentWithStatusBar(frame, healthCurrent)
        end

        if not healthPercentText then
            local percentOk, computedPercent, computedPercentText = pcall(function()
                local currentValue = runtimeUiHelpers.CoerceDisplayNumber(displayHealth) or runtimeUiHelpers.CoerceDisplayNumber(healthCurrent)
                local maxValue = runtimeUiHelpers.CoerceDisplayNumber(displayMax) or runtimeUiHelpers.CoerceDisplayNumber(healthMax)
                if type(currentValue) ~= "number" or type(maxValue) ~= "number" or maxValue <= 0 then
                    return nil, nil
                end

                local percent = currentValue / maxValue
                return percent, string.format("%d%%", math.floor((percent * 100) + 0.5))
            end)

            if percentOk then
                healthPercent = computedPercent
                healthPercentText = computedPercentText
            end
        end
    end

    ApplyCoTankBarAppearance(frame, layout, barR, barG, barB)

    if frame.healthText then
        if not isConnected then
            frame.healthText:SetText("Offline")
        elseif isDead then
            frame.healthText:SetText("Dead")
        elseif not healthTextWasApplied and healthPercentText then
            frame.healthText:SetText(healthPercentText)
        elseif not healthTextWasApplied then
            frame.healthText:SetText("--")
        end
    end
end

ApplyCoTankFrameLayout = function(frame, index, layout)
    if not frame then
        return
    end

    layout = layout or GetConfiguredLayoutSettings("cotank")
    local trackerMetrics = GetLayoutMetrics(layout)
    local coTankMetrics = GetCoTankFrameMetrics(layout)

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", 0, -((index - 1) * (coTankMetrics.frameHeight + COTANK_FRAME_GAP)))
    frame:SetSize(coTankMetrics.frameWidth, coTankMetrics.frameHeight)

    if frame.barFrame then
        frame.barFrame:ClearAllPoints()
        frame.barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.barFrame:SetSize(coTankMetrics.barWidth, coTankMetrics.barHeight)
    end

    if frame.healthBar then
        frame.healthBar:ClearAllPoints()
        frame.healthBar:SetPoint("TOPLEFT", frame.barFrame, "TOPLEFT", COTANK_BAR_STYLE.border, -COTANK_BAR_STYLE.border)
        frame.healthBar:SetPoint("BOTTOMRIGHT", frame.barFrame, "BOTTOMRIGHT", -COTANK_BAR_STYLE.border, COTANK_BAR_STYLE.border)
        if frame.healthBar.SetSize then
            frame.healthBar:SetSize(
                math.max(1, coTankMetrics.barWidth - (COTANK_BAR_STYLE.border * 2)),
                math.max(1, coTankMetrics.barHeight - (COTANK_BAR_STYLE.border * 2))
            )
        end
    end

    for buttonIndex = 1, COTANK_MAX_ICONS do
        local button = frame.auraButtons and frame.auraButtons[buttonIndex]
        if button then
            button:ClearAllPoints()
            button:SetSize(trackerMetrics.iconWidth, trackerMetrics.iconHeight)
            button:SetPoint(
                "TOPLEFT",
                frame,
                "TOPLEFT",
                (buttonIndex - 1) * (trackerMetrics.iconWidth + ICON_SPACING),
                -coTankMetrics.iconRowOffset
            )
            ApplyTextLayoutToButton(button, layout)
        end
    end

    ApplyCoTankBarAppearance(frame, layout)
end

local function ClearCoTankFrame(frame)
    if not frame then
        return
    end

    frame.unit = nil
    if frame.SetAttribute and not IsInCombat() then
        frame:SetAttribute("unit", nil)
    end
    if frame.nameText then
        frame.nameText:SetText("")
    end
    if frame.healthText then
        frame.healthText:SetText("")
    end
    if frame.healthBar and frame.healthBar.SetValue then
        frame.healthBar:SetValue(0)
    end

    for i = 1, COTANK_MAX_ICONS do
        ClearButton(frame.auraButtons and frame.auraButtons[i])
    end

    frame:Hide()
end

runtimeUiHelpers.ApplyCoTankFrameInteraction = function(frame)
    if not frame or not frame.EnableMouse then
        return
    end

    if IsInCombat() then
        return
    end

    frame:EnableMouse(not addon.editModeActive)
end

runtimeUiHelpers.ConfigureCoTankSecureFrame = function(frame, unit)
    if not frame then
        return
    end

    if frame.RegisterForClicks then
        frame:RegisterForClicks("AnyUp")
    end

    if frame.SetAttribute and not IsInCombat() then
        frame:SetAttribute("type1", "target")
        frame:SetAttribute("type2", "togglemenu")
        frame:SetAttribute("unit", unit)
    end

    if ClickCastFrames then
        ClickCastFrames[frame] = true
    end

    if unit and RegisterUnitWatch and not frame._coTankUnitWatchRegistered and not IsInCombat() then
        RegisterUnitWatch(frame)
        frame._coTankUnitWatchRegistered = true
    end
end

local function CreateCoTankFrame(parent, index)
    local frame = CreateFrame("Button", nil, parent, "SecureUnitButtonTemplate")
    frame:SetClampedToScreen(true)
    runtimeUiHelpers.ConfigureCoTankSecureFrame(frame, nil)
    runtimeUiHelpers.ApplyCoTankFrameInteraction(frame)

    local barFrame = CreateFrame("Frame", nil, frame)
    frame.barFrame = barFrame

    local barBg = barFrame:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0, 0, 0, 1)
    frame.barBg = barBg

    local function CreateBarBorder()
        local border = barFrame:CreateTexture(nil, "BORDER")
        border:SetColorTexture(0, 0, 0, 1)
        return border
    end

    local borderTop = CreateBarBorder()
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(COTANK_BAR_STYLE.border)

    local borderBottom = CreateBarBorder()
    borderBottom:SetPoint("BOTTOMLEFT")
    borderBottom:SetPoint("BOTTOMRIGHT")
    borderBottom:SetHeight(COTANK_BAR_STYLE.border)

    local borderLeft = CreateBarBorder()
    borderLeft:SetPoint("TOPLEFT")
    borderLeft:SetPoint("BOTTOMLEFT")
    borderLeft:SetWidth(COTANK_BAR_STYLE.border)

    local borderRight = CreateBarBorder()
    borderRight:SetPoint("TOPRIGHT")
    borderRight:SetPoint("BOTTOMRIGHT")
    borderRight:SetWidth(COTANK_BAR_STYLE.border)

    local nameText = barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("LEFT", barFrame, "LEFT", COTANK_BAR_STYLE.textInset, 0)
    if nameText.SetJustifyH then
        nameText:SetJustifyH("LEFT")
    end
    if nameText.SetFont and STANDARD_TEXT_FONT then
        nameText:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
    end
    if nameText.SetTextColor then
        nameText:SetTextColor(1, 1, 1, 1)
    end
    frame.nameText = nameText

    local healthText = barFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    healthText:SetPoint("RIGHT", barFrame, "RIGHT", -COTANK_BAR_STYLE.textInset, 0)
    if healthText.SetJustifyH then
        healthText:SetJustifyH("RIGHT")
    end
    if healthText.SetFont and STANDARD_TEXT_FONT then
        healthText:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
    end
    if healthText.SetTextColor then
        healthText:SetTextColor(1, 1, 1, 1)
    end
    frame.healthText = healthText

    local healthBar = CreateFrame("StatusBar", nil, frame)
    if healthBar.SetStatusBarTexture then
        healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    end
    if healthBar.SetMinMaxValues then
        healthBar:SetMinMaxValues(0, 1)
    end
    if healthBar.SetValue then
        healthBar:SetValue(1)
    end
    if healthBar.SetStatusBarColor then
        healthBar:SetStatusBarColor(0.08, 0.93, 0.62, 1)
    end
    frame.healthBar = healthBar

    local healthBarBg = healthBar:CreateTexture(nil, "BACKGROUND")
    healthBarBg:SetAllPoints()
    healthBarBg:SetColorTexture(0.04, 0.16, 0.11, 0.95)
    frame.healthBarBg = healthBarBg

    frame.auraButtons = {}
    for buttonIndex = 1, COTANK_MAX_ICONS do
        frame.auraButtons[buttonIndex] = CreateAuraButton(frame, buttonIndex)
    end

    ApplyCoTankFrameLayout(frame, index)
    ClearCoTankFrame(frame)
    return frame
end

local function EnsureCoTankFrame(index)
    if coTankFrames[index] then
        return coTankFrames[index]
    end

    local container = EnsureCoTankContainer()
    if not container then
        return nil
    end

    coTankFrames[index] = CreateCoTankFrame(container, index)
    return coTankFrames[index]
end

local function UpdateCoTankFrame(frame)
    if not frame or not frame.unit then
        return
    end

    UpdateCoTankHealthDisplay(frame)

    local auras = ScanUnitDebuffs(frame.unit, COTANK_MAX_ICONS, "cotank")
    for i = 1, COTANK_MAX_ICONS do
        ApplyAuraToButton(frame.auraButtons[i], auras[i], frame.unit, "cotank")
    end

    if not frame:IsShown() and not IsInCombat() then
        frame:Show()
    end
end

GetCoTankFrameByUnit = function(unit)
    if not unit then
        return nil
    end

    for _, frame in ipairs(coTankFrames) do
        if frame and frame.unit == unit then
            return frame
        end
    end

    return nil
end

RefreshCoTankFrames = function()
    if not trackerFrame then
        return
    end

    local layout = GetConfiguredLayoutSettings("cotank")
    local coTankMetrics = GetCoTankFrameMetrics(layout)
    local units = GetRaidTankUnits()
    local container = EnsureCoTankContainer()
    local enabled = IsCoTankFrameEnabled()
    local deferLayout = IsInCombat()

    if deferLayout then
        addon._pendingCoTankFullRefresh = true

        for _, frame in ipairs(coTankFrames) do
            if frame and frame.unit and frame:IsShown() then
                UpdateCoTankFrame(frame)
            end
        end

        return
    end

    ClearTableEntries(coTankUnits)
    if enabled then
        for index, unit in ipairs(units) do
            coTankUnits[index] = unit
        end
    end

    activeCoTankCount = #coTankUnits

    if container then
        local containerHeight = activeCoTankCount > 0
            and ((activeCoTankCount * coTankMetrics.frameHeight) + ((activeCoTankCount - 1) * COTANK_FRAME_GAP))
            or 1
        container:SetSize(coTankMetrics.frameWidth, containerHeight)
        if container.anchor then
            container.anchor:SetSize(math.max(240, coTankMetrics.frameWidth), math.max(44, coTankMetrics.barHeight))
        end
        if container.editOverlay then
            container.editOverlay:SetSize(math.max(240, coTankMetrics.frameWidth), math.max(44, coTankMetrics.frameHeight))
        end
    end

    for index, unit in ipairs(coTankUnits) do
        local frame = EnsureCoTankFrame(index)
        if frame then
            frame.unit = unit
            runtimeUiHelpers.ConfigureCoTankSecureFrame(frame, unit)
            ApplyCoTankFrameLayout(frame, index, layout)
            UpdateCoTankFrame(frame)
        end
    end

    for index = activeCoTankCount + 1, #coTankFrames do
        ClearCoTankFrame(coTankFrames[index])
    end

    if container then
        ApplyCoTankContainerPosition()
        if activeCoTankCount > 0 or addon.editModeActive then
            container:Show()
        else
            container:Hide()
        end
    end

    addon._pendingCoTankFullRefresh = false
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
    anchor:SetScript("OnClick", function(self)
        local now = GetTime and GetTime() or 0
        if self.lastDragTime and (now - self.lastDragTime) < 0.05 then
            return
        end
        if addon.editModeActive and addon.OpenLayoutEditor then
            addon:OpenLayoutEditor()
        end
    end)
    anchor:SetScript("OnDragStart", function(self)
        self.lastDragTime = nil
        if addon.editModeActive and trackerFrame and trackerFrame.StartMoving then
            trackerFrame:StartMoving()
        end
    end)
    anchor:SetScript("OnDragStop", function(self)
        if trackerFrame and trackerFrame.StopMovingOrSizing then
            trackerFrame:StopMovingOrSizing()
        end
        self.lastDragTime = GetTime and GetTime() or 0
        if addon and addon.SaveTrackerPosition then
            addon:SaveTrackerPosition()
        end
    end)
    anchor:Hide()
    return anchor
end

local function CreateCoTankAnchor(parent)
    local metrics = GetCoTankFrameMetrics(GetConfiguredLayoutSettings("cotank"))
    local anchor = CreateFrame("Button", nil, parent, "BackdropTemplate")
    anchor:SetPoint("TOPLEFT", 0, 0)
    anchor:SetSize(math.max(240, metrics.frameWidth), math.max(44, metrics.barHeight))
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
    label:SetPoint("LEFT", 14, 0)
    label:SetText("|cff00ccffCo-Tank Frames|r")

    local settingsButton = CreateFrame("Button", nil, anchor, "UIPanelButtonTemplate")
    settingsButton:SetSize(62, 20)
    settingsButton:SetPoint("RIGHT", -10, 0)
    settingsButton:SetText("Layout")
    settingsButton:SetScript("OnClick", function()
        if addon.editModeActive and addon.OpenLayoutEditor then
            addon:OpenLayoutEditor("cotank")
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
    anchor:SetScript("OnClick", function(self)
        local now = GetTime and GetTime() or 0
        if self.lastDragTime and (now - self.lastDragTime) < 0.05 then
            return
        end
        if addon.editModeActive and addon.OpenLayoutEditor then
            addon:OpenLayoutEditor("cotank")
        end
    end)
    anchor:SetScript("OnDragStart", function(self)
        self.lastDragTime = nil
        if addon.editModeActive and coTankContainer and coTankContainer.StartMoving then
            coTankDragActive = true
            coTankContainer:StartMoving()
        end
    end)
    anchor:SetScript("OnDragStop", function(self)
        if coTankContainer and coTankContainer.StopMovingOrSizing then
            coTankContainer:StopMovingOrSizing()
        end
        coTankDragActive = false
        self.lastDragTime = GetTime and GetTime() or 0
        if addon and addon.SaveCoTankPosition then
            addon:SaveCoTankPosition()
        end
    end)
    anchor:Hide()
    return anchor
end

function addon:CreateCoTankEditModeOverlay()
    local metrics = GetCoTankFrameMetrics(GetConfiguredLayoutSettings("cotank"))
    local overlay = CreateFrame("Frame", nil, coTankContainer, "BackdropTemplate")
    overlay:SetPoint("TOPLEFT", 0, 0)
    overlay:SetSize(math.max(240, metrics.frameWidth), math.max(44, metrics.frameHeight))
    if coTankContainer.GetFrameLevel and overlay.SetFrameLevel then
        overlay:SetFrameLevel(coTankContainer:GetFrameLevel() + 5)
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

    local barFrame = CreateFrame("Frame", nil, overlay)
    barFrame:SetPoint("TOPLEFT", 0, 0)
    barFrame:SetSize(metrics.barWidth, metrics.barHeight)
    overlay.previewBarFrame = barFrame

    local barFrameBg = barFrame:CreateTexture(nil, "BACKGROUND")
    barFrameBg:SetAllPoints()
    barFrameBg:SetColorTexture(0, 0, 0, 0.65)

    local function CreatePreviewBorder()
        local border = barFrame:CreateTexture(nil, "BORDER")
        border:SetColorTexture(0.90, 0.96, 0.96, 0.22)
        return border
    end

    local previewTop = CreatePreviewBorder()
    previewTop:SetPoint("TOPLEFT")
    previewTop:SetPoint("TOPRIGHT")
    previewTop:SetHeight(COTANK_BAR_STYLE.border)

    local previewBottom = CreatePreviewBorder()
    previewBottom:SetPoint("BOTTOMLEFT")
    previewBottom:SetPoint("BOTTOMRIGHT")
    previewBottom:SetHeight(COTANK_BAR_STYLE.border)

    local previewLeft = CreatePreviewBorder()
    previewLeft:SetPoint("TOPLEFT")
    previewLeft:SetPoint("BOTTOMLEFT")
    previewLeft:SetWidth(COTANK_BAR_STYLE.border)

    local previewRight = CreatePreviewBorder()
    previewRight:SetPoint("TOPRIGHT")
    previewRight:SetPoint("BOTTOMRIGHT")
    previewRight:SetWidth(COTANK_BAR_STYLE.border)

    local bar = overlay:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", barFrame, "TOPLEFT", COTANK_BAR_STYLE.border, -COTANK_BAR_STYLE.border)
    bar:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", -COTANK_BAR_STYLE.border, COTANK_BAR_STYLE.border)
    bar:SetColorTexture(0.08, 0.93, 0.62, 0.45)
    overlay.previewBar = bar

    overlay.previewIcons = {}
    for index, textureID in ipairs(EDIT_PREVIEW_ICONS) do
        local icon = overlay:CreateTexture(nil, "ARTWORK")
        icon:SetSize(16, 16)
        icon:SetPoint("TOPLEFT", 0 + ((index - 1) * 18), -(metrics.iconRowOffset + 2))
        icon:SetTexture(textureID)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetAlpha(0)
        overlay.previewIcons[index] = icon
    end

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", barFrame, "LEFT", COTANK_BAR_STYLE.textInset, 0)
    if label.SetFont and STANDARD_TEXT_FONT then
        label:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
    end
    label:SetText("")

    overlay.allTex = { bg, borderTop, borderBottom, borderLeft, borderRight }
    overlay.label = label
    overlay.borderTop = borderTop
    overlay.borderBottom = borderBottom
    overlay.borderLeft = borderLeft
    overlay.borderRight = borderRight
    overlay:Hide()
    coTankContainer.editOverlay = overlay
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

local function GetLayoutEditorTargetKey()
    return layoutEditorFrame and GetLayoutTargetKey(layoutEditorFrame.targetKey) or "tracker"
end

local function UpdateLayoutEditorChrome()
    if not layoutEditorFrame then
        return
    end

    local targetKey = GetLayoutEditorTargetKey()
    if layoutEditorFrame.titleText then
        if targetKey == "cotank" then
            layoutEditorFrame.titleText:SetText("|cff00ccffDebuff Tracker|r Co-Tank Layout")
        else
            layoutEditorFrame.titleText:SetText("|cff00ccffDebuff Tracker|r Layout")
        end
    end

    if layoutEditorFrame.subtitleText then
        if targetKey == "cotank" then
            layoutEditorFrame.subtitleText:SetText("Open this from the Co-Tank Edit Mode anchor. Adjust health bar width, height, solid colors, text size, plus debuff icon styling.")
        else
            layoutEditorFrame.subtitleText:SetText("Open this from Edit Mode. Drag the left edge to widen and the top edge to increase height.")
        end
    end

    if layoutEditorFrame.previewHint then
        if targetKey == "cotank" then
            layoutEditorFrame.previewHint:SetText("Preview shows a co-tank health bar plus one debuff icon. Use the bar controls on the right for width, height, text size, and colors. Drag 2 / 8.8 to reposition debuff text.")
        else
            layoutEditorFrame.previewHint:SetText("Drag the left edge for width, the top edge for height, and drag 2 / 8.8 to reposition text")
        end
    end

    if layoutEditorFrame.previewHealthBar then
        if targetKey == "cotank" then
            layoutEditorFrame.previewHealthBar:Show()
        else
            layoutEditorFrame.previewHealthBar:Hide()
        end
    end
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

    UpdateLayoutEditorChrome()

    local targetKey = GetLayoutEditorTargetKey()
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
    if targetKey == "cotank" then
        if layoutEditorFrame.coTankFrameWidthInput then
            layoutEditorFrame.coTankFrameWidthInput:SetText(tostring(ClampCoTankFrameWidth(layout.frameWidth)))
        end
        if layoutEditorFrame.coTankBarHeightInput then
            layoutEditorFrame.coTankBarHeightInput:SetText(tostring(ClampCoTankBarHeight(layout.barHeight)))
        end
        if layoutEditorFrame.coTankBarTextSizeInput then
            layoutEditorFrame.coTankBarTextSizeInput:SetText(tostring(ClampFontSize(layout.barTextFontSize or 16)))
        end
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

    if layoutEditorFrame.previewHealthBarFrame and layoutEditorFrame.previewHealthBar then
        if targetKey == "cotank" then
            local metrics = GetCoTankFrameMetrics(layout)
            local fillColor = CloneBorderColor(layout.barFillColor)
            local bgColor = CloneBorderColor(layout.barBackgroundColor)
            local fillR, fillG, fillB = fillColor.r, fillColor.g, fillColor.b
            local bgR, bgG, bgB = bgColor.r, bgColor.g, bgColor.b
            local fontSize = ClampFontSize(layout.barTextFontSize or 16)
            layoutEditorFrame.previewHealthBarFrame:Show()
            layoutEditorFrame.previewHealthBarFrame:ClearAllPoints()
            layoutEditorFrame.previewHealthBarFrame:SetPoint("TOPLEFT", layoutEditorFrame.previewArea, "TOPLEFT", 24, -34)
            layoutEditorFrame.previewHealthBarFrame:SetSize(metrics.barWidth, metrics.barHeight)
            layoutEditorFrame.previewHealthBar:SetStatusBarColor(fillR, fillG, fillB, 1)
            if layoutEditorFrame.previewHealthBarBg then
                layoutEditorFrame.previewHealthBarBg:SetColorTexture(bgR, bgG, bgB, 0.95)
            end
            if layoutEditorFrame.previewHealthName and layoutEditorFrame.previewHealthName.SetFont and STANDARD_TEXT_FONT then
                layoutEditorFrame.previewHealthName:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
                layoutEditorFrame.previewHealthName:SetText("Wisently")
            end
            if layoutEditorFrame.previewHealthValue and layoutEditorFrame.previewHealthValue.SetFont and STANDARD_TEXT_FONT then
                layoutEditorFrame.previewHealthValue:SetFont(STANDARD_TEXT_FONT, fontSize, "OUTLINE")
                layoutEditorFrame.previewHealthValue:SetText("100%")
            end
            layoutEditorFrame.previewGroup:ClearAllPoints()
            layoutEditorFrame.previewGroup:SetPoint("TOPLEFT", layoutEditorFrame.previewHealthBarFrame, "BOTTOMLEFT", 0, -COTANK_BAR_STYLE.iconGap)
        else
            layoutEditorFrame.previewHealthBarFrame:Hide()
            layoutEditorFrame.previewGroup:ClearAllPoints()
            layoutEditorFrame.previewGroup:SetPoint("BOTTOMRIGHT", layoutEditorFrame.previewArea, "CENTER", 42, -18)
        end
    end

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
    if targetKey == "cotank" then
        local fillColor = CloneBorderColor(layout.barFillColor)
        local bgColor = CloneBorderColor(layout.barBackgroundColor)
        if layoutEditorFrame.coTankFillPreview then
            layoutEditorFrame.coTankFillPreview:SetColorTexture(fillColor.r, fillColor.g, fillColor.b, 1)
        end
        if layoutEditorFrame.coTankBgPreview then
            layoutEditorFrame.coTankBgPreview:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, 1)
        end
    end

    SetLayoutEditorControlsShown(layoutEditorFrame.iconControls, selectedElementKey == "icon")
    SetLayoutEditorControlsShown(layoutEditorFrame.textControls, selectedElementKey ~= "icon")
    SetLayoutEditorControlsShown(layoutEditorFrame.customColorControls, selectedElementKey == "icon" and state.borderMode ~= "blizzard")
    SetLayoutEditorControlsShown(layoutEditorFrame.coTankAppearanceControls, targetKey == "cotank")
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
    runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
        RefreshLayoutEditorPreview()
    end)
end

local function OpenLayoutEditorColorPicker(colorTarget)
    if not layoutEditorFrame or not layoutEditorFrame.state then
        return
    end

    if not ColorPickerFrame or not ColorPickerFrame.SetupColorPickerAndShow then
        return
    end

    local usingLayoutColor = colorTarget == "barFillColor" or colorTarget == "barBackgroundColor"
    local current = usingLayoutColor
        and CloneBorderColor(layoutEditorFrame.state.layout[colorTarget])
        or CloneBorderColor(layoutEditorFrame.state.customBorderColor)

    ColorPickerFrame:SetupColorPickerAndShow({
        r = current.r,
        g = current.g,
        b = current.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            if usingLayoutColor then
                layoutEditorFrame.state.layout[colorTarget] = { r = r, g = g, b = b }
            else
                layoutEditorFrame.state.borderMode = "custom"
                layoutEditorFrame.state.customBorderColor = { r = r, g = g, b = b }
            end
            runtimeUiHelpers.MarkLayoutEditorDirty()
            RefreshLayoutEditorPreview()
        end,
        cancelFunc = function()
            if usingLayoutColor then
                layoutEditorFrame.state.layout[colorTarget] = current
            else
                layoutEditorFrame.state.customBorderColor = current
            end
            RefreshLayoutEditorPreview()
        end,
    })
end

local function CommitLayoutEditorState()
    if not layoutEditorFrame or not layoutEditorFrame.state or not addon or not addon.db then
        return
    end

    local targetKey = GetLayoutEditorTargetKey()
    addon.db[GetLayoutDbKey(targetKey)] = CloneLayoutSettings(layoutEditorFrame.state.layout, targetKey)
    addon.db[GetBorderModeDbKey(targetKey)] = layoutEditorFrame.state.borderMode
    addon.db[GetBorderColorDbKey(targetKey)] = CloneBorderColor(layoutEditorFrame.state.customBorderColor)

    RefreshTrackerLayout()
    addon:UpdateTrackedAuras("layout-editor-apply")
    layoutEditorFrame.hasPendingChanges = false
    layoutEditorFrame.discardChangesOnHide = false
end

local function ResetLayoutEditorState()
    if not layoutEditorFrame then
        return
    end

    local targetKey = GetLayoutEditorTargetKey()
    layoutEditorFrame.state = {
        layout = GetDefaultLayoutSettings(targetKey),
        borderMode = "custom",
        customBorderColor = { r = 0, g = 0, b = 0 },
    }
    layoutEditorFrame.selectedElementKey = "icon"
    layoutEditorFrame.selectedTextKey = "count"
    runtimeUiHelpers.MarkLayoutEditorDirty()
    RefreshLayoutEditorPreview()
end

local function LoadLayoutEditorState(targetKey)
    targetKey = GetLayoutTargetKey(targetKey or GetLayoutEditorTargetKey())
    layoutEditorFrame.targetKey = targetKey
    layoutEditorFrame.state = {
        layout = CloneLayoutSettings(GetConfiguredLayoutSettings(targetKey), targetKey),
        borderMode = addon and addon.db and addon.db[GetBorderModeDbKey(targetKey)] or "custom",
        customBorderColor = CloneBorderColor(addon and addon.db and addon.db[GetBorderColorDbKey(targetKey)] or nil),
    }
    layoutEditorFrame.selectedElementKey = layoutEditorFrame.selectedElementKey or "icon"
    layoutEditorFrame.selectedTextKey = layoutEditorFrame.selectedTextKey or "count"
    layoutEditorFrame.hasPendingChanges = false
    layoutEditorFrame.discardChangesOnHide = false
    UpdateLayoutEditorChrome()
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

local function CreateLayoutEditorPreviewHealthBar(frame, previewArea)
    local previewHealthBarFrame = CreateFrame("Frame", nil, previewArea)
    previewHealthBarFrame:SetPoint("TOPLEFT", previewArea, "TOPLEFT", 24, -34)
    previewHealthBarFrame:SetSize(252, 44)
    frame.previewHealthBarFrame = previewHealthBarFrame

    local previewHealthBarFrameBg = previewHealthBarFrame:CreateTexture(nil, "BACKGROUND")
    previewHealthBarFrameBg:SetAllPoints()
    previewHealthBarFrameBg:SetColorTexture(0, 0, 0, 1)

    local function CreatePreviewHealthBorder()
        local border = previewHealthBarFrame:CreateTexture(nil, "BORDER")
        border:SetColorTexture(0, 0, 0, 1)
        return border
    end

    local previewHealthTop = CreatePreviewHealthBorder()
    previewHealthTop:SetPoint("TOPLEFT")
    previewHealthTop:SetPoint("TOPRIGHT")
    previewHealthTop:SetHeight(COTANK_BAR_STYLE.border)

    local previewHealthBottom = CreatePreviewHealthBorder()
    previewHealthBottom:SetPoint("BOTTOMLEFT")
    previewHealthBottom:SetPoint("BOTTOMRIGHT")
    previewHealthBottom:SetHeight(COTANK_BAR_STYLE.border)

    local previewHealthLeft = CreatePreviewHealthBorder()
    previewHealthLeft:SetPoint("TOPLEFT")
    previewHealthLeft:SetPoint("BOTTOMLEFT")
    previewHealthLeft:SetWidth(COTANK_BAR_STYLE.border)

    local previewHealthRight = CreatePreviewHealthBorder()
    previewHealthRight:SetPoint("TOPRIGHT")
    previewHealthRight:SetPoint("BOTTOMRIGHT")
    previewHealthRight:SetWidth(COTANK_BAR_STYLE.border)

    local previewHealthBar = CreateFrame("StatusBar", nil, previewHealthBarFrame)
    previewHealthBar:SetPoint("TOPLEFT", previewHealthBarFrame, "TOPLEFT", COTANK_BAR_STYLE.border, -COTANK_BAR_STYLE.border)
    previewHealthBar:SetPoint("BOTTOMRIGHT", previewHealthBarFrame, "BOTTOMRIGHT", -COTANK_BAR_STYLE.border, COTANK_BAR_STYLE.border)
    if previewHealthBar.SetStatusBarTexture then
        previewHealthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    end
    if previewHealthBar.SetMinMaxValues then
        previewHealthBar:SetMinMaxValues(0, 100)
    end
    if previewHealthBar.SetValue then
        previewHealthBar:SetValue(100)
    end
    if previewHealthBar.SetStatusBarColor then
        previewHealthBar:SetStatusBarColor(0.08, 0.93, 0.62, 1)
    end
    local previewHealthBarBg = previewHealthBar:CreateTexture(nil, "BACKGROUND")
    previewHealthBarBg:SetAllPoints()
    previewHealthBarBg:SetColorTexture(0.04, 0.16, 0.11, 0.95)
    frame.previewHealthBar = previewHealthBar
    frame.previewHealthBarBg = previewHealthBarBg

    local previewHealthName = previewHealthBarFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewHealthName:SetPoint("LEFT", previewHealthBarFrame, "LEFT", COTANK_BAR_STYLE.textInset, 0)
    previewHealthName:SetText("Wisently")
    frame.previewHealthName = previewHealthName

    local previewHealthValue = previewHealthBarFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    previewHealthValue:SetPoint("RIGHT", previewHealthBarFrame, "RIGHT", -COTANK_BAR_STYLE.textInset, 0)
    previewHealthValue:SetText("100%")
    frame.previewHealthValue = previewHealthValue

    previewHealthBar:Hide()
    previewHealthBarFrame:Hide()
end

local function CreateLayoutEditorCoTankControls(frame, controls, TrackControl)
    local coTankAppearanceLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    coTankAppearanceLabel:SetPoint("TOPLEFT", 14, -434)
    coTankAppearanceLabel:SetText("Co-Tank Bar")
    TrackControl(coTankAppearanceLabel, "coTankAppearanceControls")

    local coTankWidthLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    coTankWidthLabel:SetPoint("TOPLEFT", 14, -456)
    coTankWidthLabel:SetText("Width")
    TrackControl(coTankWidthLabel, "coTankAppearanceControls")

    local coTankWidthInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    coTankWidthInput:SetSize(48, 22)
    coTankWidthInput:SetPoint("TOPLEFT", 14, -476)
    coTankWidthInput:SetAutoFocus(false)
    coTankWidthInput:SetNumeric(true)
    frame.coTankFrameWidthInput = coTankWidthInput
    TrackControl(coTankWidthInput, "coTankAppearanceControls")

    local coTankHeightLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    coTankHeightLabel:SetPoint("TOPLEFT", 78, -456)
    coTankHeightLabel:SetText("Height")
    TrackControl(coTankHeightLabel, "coTankAppearanceControls")

    local coTankHeightInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    coTankHeightInput:SetSize(48, 22)
    coTankHeightInput:SetPoint("TOPLEFT", 78, -476)
    coTankHeightInput:SetAutoFocus(false)
    coTankHeightInput:SetNumeric(true)
    frame.coTankBarHeightInput = coTankHeightInput
    TrackControl(coTankHeightInput, "coTankAppearanceControls")

    local coTankTextSizeLabel = controls:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    coTankTextSizeLabel:SetPoint("TOPLEFT", 142, -456)
    coTankTextSizeLabel:SetText("Text")
    TrackControl(coTankTextSizeLabel, "coTankAppearanceControls")

    local coTankTextSizeInput = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    coTankTextSizeInput:SetSize(48, 22)
    coTankTextSizeInput:SetPoint("TOPLEFT", 142, -476)
    coTankTextSizeInput:SetAutoFocus(false)
    coTankTextSizeInput:SetNumeric(true)
    frame.coTankBarTextSizeInput = coTankTextSizeInput
    TrackControl(coTankTextSizeInput, "coTankAppearanceControls")

    local function ApplyManualCoTankBarSettings()
        if not frame.state then
            return
        end

        frame.state.layout.frameWidth = ClampCoTankFrameWidth(coTankWidthInput:GetText())
        frame.state.layout.barHeight = ClampCoTankBarHeight(coTankHeightInput:GetText())
        frame.state.layout.barTextFontSize = ClampFontSize(coTankTextSizeInput:GetText())
        runtimeUiHelpers.MarkLayoutEditorDirty()
        RefreshLayoutEditorPreview()
    end

    coTankWidthInput:SetScript("OnEnterPressed", function(self)
        ApplyManualCoTankBarSettings()
        self:ClearFocus()
    end)
    coTankHeightInput:SetScript("OnEnterPressed", function(self)
        ApplyManualCoTankBarSettings()
        self:ClearFocus()
    end)
    coTankTextSizeInput:SetScript("OnEnterPressed", function(self)
        ApplyManualCoTankBarSettings()
        self:ClearFocus()
    end)

    local coTankApplySizeButton = CreateEditorButton(controls, 52, 22, "Set")
    coTankApplySizeButton:SetPoint("TOPLEFT", 204, -476)
    coTankApplySizeButton:SetScript("OnClick", ApplyManualCoTankBarSettings)
    TrackControl(coTankApplySizeButton, "coTankAppearanceControls")

    local coTankFillButton = CreateEditorButton(controls, 92, 22, "Fill Color")
    coTankFillButton:SetPoint("TOPLEFT", 14, -514)
    coTankFillButton:SetScript("OnClick", function()
        OpenLayoutEditorColorPicker("barFillColor")
    end)
    TrackControl(coTankFillButton, "coTankAppearanceControls")

    local coTankFillPreview = CreateFrame("Frame", nil, controls, "BackdropTemplate")
    coTankFillPreview:SetSize(24, 22)
    coTankFillPreview:SetPoint("LEFT", coTankFillButton, "RIGHT", 8, 0)
    coTankFillPreview:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local coTankFillPreviewTex = coTankFillPreview:CreateTexture(nil, "ARTWORK")
    coTankFillPreviewTex:SetPoint("TOPLEFT", 3, -3)
    coTankFillPreviewTex:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.coTankFillPreview = coTankFillPreviewTex
    TrackControl(coTankFillPreview, "coTankAppearanceControls")

    local coTankBgButton = CreateEditorButton(controls, 96, 22, "Bar BG")
    coTankBgButton:SetPoint("TOPLEFT", 136, -514)
    coTankBgButton:SetScript("OnClick", function()
        OpenLayoutEditorColorPicker("barBackgroundColor")
    end)
    TrackControl(coTankBgButton, "coTankAppearanceControls")

    local coTankBgPreview = CreateFrame("Frame", nil, controls, "BackdropTemplate")
    coTankBgPreview:SetSize(24, 22)
    coTankBgPreview:SetPoint("LEFT", coTankBgButton, "RIGHT", 8, 0)
    coTankBgPreview:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local coTankBgPreviewTex = coTankBgPreview:CreateTexture(nil, "ARTWORK")
    coTankBgPreviewTex:SetPoint("TOPLEFT", 3, -3)
    coTankBgPreviewTex:SetPoint("BOTTOMRIGHT", -3, 3)
    frame.coTankBgPreview = coTankBgPreviewTex
    TrackControl(coTankBgPreview, "coTankAppearanceControls")

    local coTankAppearanceHelp = CreateEditorWrappedText(
        controls,
        "These settings control the co-tank health bar width, height, text size, and solid colors from Edit Mode.",
        226
    )
    coTankAppearanceHelp:SetPoint("TOPLEFT", 14, -548)
    TrackControl(coTankAppearanceHelp, "coTankAppearanceControls")
end

function addon:CreateLayoutEditor()
    if layoutEditorFrame then
        return layoutEditorFrame
    end

    local frame = CreateFrame("Frame", "DebuffTrackLayoutEditorFrame", UIParent, "BackdropTemplate")
    frame:SetSize(720, 620)
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
    frame.titleText = title

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    subtitle:SetPoint("TOPLEFT", 18, -38)
    subtitle:SetText("Open this from Edit Mode. Drag the left edge to widen and the top edge to increase height.")
    frame.subtitleText = subtitle

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    local previewArea = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    previewArea:SetPoint("TOPLEFT", 18, -66)
    previewArea:SetSize(410, 360)
    previewArea:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    previewArea:SetBackdropColor(0.07, 0.07, 0.08, 0.94)
    previewArea:SetBackdropBorderColor(0.22, 0.22, 0.24, 1)
    frame.previewArea = previewArea

    local previewHint = previewArea:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    previewHint:SetPoint("BOTTOM", 0, 14)
    previewHint:SetText("Drag the left edge for width, the top edge for height, and drag 2 / 8.8 to reposition text")
    frame.previewHint = previewHint
    CreateLayoutEditorPreviewHealthBar(frame, previewArea)

    local previewGroup = CreateFrame("Frame", nil, previewArea)
    previewGroup:SetPoint("TOPLEFT", previewHealthBarFrame, "BOTTOMLEFT", 0, -COTANK_BAR_STYLE.iconGap)
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
    controls:SetSize(256, 510)
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
    frame.coTankAppearanceControls = {}

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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
        runtimeUiHelpers.MarkLayoutEditorDirty()
        RefreshLayoutEditorPreview()
    end)
    frame.customModeButton = customModeButton
    TrackControl(customModeButton, "iconControls")

    local blizzardModeButton = CreateEditorButton(controls, 110, 22, "Blizzard")
    blizzardModeButton:SetPoint("LEFT", customModeButton, "RIGHT", 8, 0)
    blizzardModeButton:SetScript("OnClick", function()
        frame.state.borderMode = "blizzard"
        runtimeUiHelpers.MarkLayoutEditorDirty()
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
    CreateLayoutEditorCoTankControls(frame, controls, TrackControl)

    local cancelButton = CreateEditorButton(frame, 180, 24, "Cancel")
    cancelButton:SetPoint("BOTTOMLEFT", 18, 18)
    cancelButton:SetScript("OnClick", function()
        frame.discardChangesOnHide = true
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
    frame.targetKey = "tracker"
    frame.selectedElementKey = "icon"
    frame.selectedTextKey = "count"
    frame:SetScript("OnHide", function()
        if frame.hasPendingChanges and not frame.discardChangesOnHide then
            CommitLayoutEditorState()
        end
        frame.hasPendingChanges = false
        frame.discardChangesOnHide = false
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

function addon:OpenLayoutEditor(targetKey)
    if not addon.editModeActive then
        return
    end

    if not layoutEditorFrame then
        addon:CreateLayoutEditor()
    end

    local normalizedTargetKey = GetLayoutTargetKey(targetKey)
    if layoutEditorFrame:IsShown() and layoutEditorFrame.hasPendingChanges
        and layoutEditorFrame.targetKey ~= normalizedTargetKey
    then
        CommitLayoutEditorState()
    end

    LoadLayoutEditorState(normalizedTargetKey)
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

    if coTankContainer then
        coTankContainer:SetMovable(true)
        coTankContainer:EnableMouse(true)
        coTankContainer:RegisterForDrag("LeftButton")
        coTankContainer:SetScript("OnDragStart", function(self)
            coTankDragActive = true
            self:StartMoving()
        end)
        coTankContainer:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            coTankDragActive = false
            addon:SaveCoTankPosition()
        end)

        local coTankOverlay = coTankContainer.editOverlay
        if coTankOverlay then
            coTankOverlay:Show()
            coTankOverlay:SetBackdropColor(0.48, 0.62, 0.64, 0.34)
            coTankOverlay:SetBackdropBorderColor(0.86, 0.94, 0.94, 0.95)
            coTankOverlay.bg:SetColorTexture(0, 0, 0, 0)
            for _, texture in ipairs(coTankOverlay.allTex) do
                texture:SetVertexColor(0.88, 0.96, 0.96, 0.22)
            end
            coTankOverlay.bg:SetVertexColor(1, 1, 1, 1)
            if coTankOverlay.previewIcons then
                for _, icon in ipairs(coTankOverlay.previewIcons) do
                    icon:SetAlpha(0.95)
                end
            end
            coTankOverlay.label:SetText("")
        end

        if coTankContainer.anchor and coTankContainer.anchor.EnableMouse then
            coTankContainer.anchor:EnableMouse(true)
        end
        coTankContainer:Show()
    end

    UpdateTrackerStrata()
    RefreshButtonPresentation()
    UpdateAnchorVisibility()
    for _, frame in ipairs(coTankFrames) do
        runtimeUiHelpers.ApplyCoTankFrameInteraction(frame)
    end
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

    if coTankContainer then
        coTankDragActive = false
        coTankContainer:SetMovable(false)
        coTankContainer:EnableMouse(false)
        coTankContainer:RegisterForDrag()
        coTankContainer:SetScript("OnDragStart", nil)
        coTankContainer:SetScript("OnDragStop", nil)

        local coTankOverlay = coTankContainer.editOverlay
        if coTankOverlay then
            coTankOverlay.bg:SetColorTexture(0, 0, 0, 0)
            coTankOverlay:SetBackdropColor(0, 0, 0, 0)
            coTankOverlay:SetBackdropBorderColor(0, 0, 0, 0)
            for _, texture in ipairs(coTankOverlay.allTex) do
                texture:SetVertexColor(0, 0, 0, 0)
            end
            if coTankOverlay.previewIcons then
                for _, icon in ipairs(coTankOverlay.previewIcons) do
                    icon:SetAlpha(0)
                end
            end
            coTankOverlay.label:SetText("")
            coTankOverlay:Hide()
        end

        if coTankContainer.anchor and coTankContainer.anchor.EnableMouse then
            coTankContainer.anchor:EnableMouse(false)
        end
    end
    if layoutEditorFrame and layoutEditorFrame.Hide then
        layoutEditorFrame:Hide()
    end

    addon:SaveTrackerPosition()
    addon:SaveCoTankPosition()
    UpdateTrackerStrata()
    RefreshButtonPresentation()
    UpdateAnchorVisibility()
    for _, frame in ipairs(coTankFrames) do
        runtimeUiHelpers.ApplyCoTankFrameInteraction(frame)
    end
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

    for _, frame in ipairs(coTankFrames) do
        if frame and frame.auraButtons and frame:IsShown() then
            for _, button in ipairs(frame.auraButtons) do
                if button and button:IsShown() then
                    UpdateDuration(button, now)
                end
            end
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

    EnsureCoTankContainer()
    if coTankContainer and coTankContainer.SetFrameStrata then
        coTankContainer:SetFrameStrata(TRACKER_NORMAL_STRATA)
    end
    if coTankContainer and coTankContainer.SetFrameLevel and trackerFrame.GetFrameLevel then
        coTankContainer:SetFrameLevel(trackerFrame:GetFrameLevel() + 2)
    end
    if coTankContainer and not coTankContainer.anchor then
        coTankContainer.anchor = CreateCoTankAnchor(coTankContainer)
    end
    trackerFrame.anchor = CreateAnchor(trackerFrame)

    addon:CreateEditModeOverlay()
    if coTankContainer and not coTankContainer.editOverlay then
        addon:CreateCoTankEditModeOverlay()
    end
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
    addon.CoTankContainer = coTankContainer
    addon.CoTankFrames = coTankFrames
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
                    local tooltipSpellId = GetTooltipSpellIDByAuraIndex("player", aura.auraIndex, aura.queryFilter)
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
        local tooltipDebug = aura and aura.auraIndex and GetTooltipAuraDebugByAuraIndex("player", aura.auraIndex, aura.queryFilter) or nil
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

function addon:SaveCoTankPosition()
    if not coTankContainer then
        return
    end

    local point, _, relPoint, x, y = coTankContainer:GetPoint()
    addon.db.coTankFramePosition = {
        point = point,
        relativePoint = relPoint,
        x = x,
        y = y,
        relativeTo = "UIParent",
    }
end

function addon:ResetCoTankPosition()
    if not coTankContainer then
        return
    end

    addon.db.coTankFramePosition = ConvertLegacyCoTankPosition(GetDefaultCoTankPosition())
    ApplyCoTankContainerPosition(true)
end

function addon:UpdateTrackerLock()
    UpdateAnchorVisibility()
end
