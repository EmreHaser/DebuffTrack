local addonName, addon = ...
DebuffAddon = addon

addon.version = "1.0.0"

-- Default saved-variable structure
local defaults = {
    trackedSpells = {},   -- [spellId] = true
    manualSpells  = {},   -- [spellId] = true
    trackAllDebuffs = false,
    auraFilter = "HARMFUL|RAID",
    borderMode = "custom", -- "custom" | "blizzard"
    customBorderColor = {
        r = 0,
        g = 0,
        b = 0,
    },
    layout = {
        iconWidth = 36,
        iconHeight = 36,
        borderThickness = 2,
        countOffsetX = 12,
        countOffsetY = -10,
        countFontSize = 18,
        durationOffsetX = 0,
        durationOffsetY = -26,
        durationFontSize = 16,
    },
    framePosition = {
        point         = "CENTER",
        relativePoint = "CENTER",
        x             = 0,
        y             = 0,
    },
    locked = false,
}

local function ApplyDefaultsToDb(target)
    if not target then
        return
    end

    wipe(target)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            target[k] = CopyTable(v)
        else
            target[k] = v
        end
    end
end

------------------------------------------------------------
-- Bootstrap: load saved variables, init tracker
------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        if not DebuffAddonDB then
            DebuffAddonDB = {}
        end

        -- Fill in any missing default keys
        for k, v in pairs(defaults) do
            if DebuffAddonDB[k] == nil then
                if type(v) == "table" then
                    DebuffAddonDB[k] = CopyTable(v)
                else
                    DebuffAddonDB[k] = v
                end
            end
        end

        addon.db = DebuffAddonDB
        addon.db.trackAllDebuffs = false

        -- Wait for PLAYER_LOGIN to init tracker (avoids C_Timer.After taint)
        self:RegisterEvent("PLAYER_LOGIN")

        self:UnregisterEvent("ADDON_LOADED")
    print("|cff00ccffDebuff Tracker|r v" .. addon.version .. " loaded.  |cff00ff00/dba|r for settings.  Use |cff00ff00Edit Mode|r to reposition.")

    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if addon.InitTracker then
            addon:InitTracker()
        end

    elseif event == "PLAYER_LOGOUT" then
        -- Persist tracker position before logout
        if addon.SaveTrackerPosition then
            addon:SaveTrackerPosition()
        end
    end
end)

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
SLASH_DEBUFFADDON1 = "/debuffaddon"
SLASH_DEBUFFADDON2 = "/dba"

SlashCmdList["DEBUFFADDON"] = function(msg)
    msg = strtrim(msg or ""):lower()

    -- Safety: make sure DB is loaded
    if not addon.db then
            print("|cff00ccffDebuff Tracker|r: Not loaded yet — try /reload first.")
        return
    end

    if msg == "lock" then
        addon.db.locked = not addon.db.locked
        if addon.db.locked then
                print("|cff00ccffDebuff Tracker|r: Tracker |cffff0000locked|r.")
        else
                print("|cff00ccffDebuff Tracker|r: Tracker |cff00ff00unlocked|r.")
        end
        if addon.UpdateTrackerLock then
            addon:UpdateTrackerLock()
        end
        return
    end

    if msg == "reset" then
        addon.db.framePosition = CopyTable(defaults.framePosition)
        if addon.ResetTrackerPosition then
            addon:ResetTrackerPosition()
        end
            print("|cff00ccffDebuff Tracker|r: Tracker position reset.")
        return
    end

    if msg == "scan" then
        if addon.DiagnosticScan then
            addon:DiagnosticScan()
        else
                print("|cff00ccffDebuff Tracker|r: DiagnosticScan not available.")
        end
        return
    end

    if msg == "cache" then
        if addon.DiagnosticCache then
            addon:DiagnosticCache()
        else
                print("|cff00ccffDebuff Tracker|r: DiagnosticCache not available.")
        end
        return
    end

    if msg == "api" then
        if addon.OpenApiDebugFrame then
            addon:OpenApiDebugFrame()
        else
                print("|cff00ccffDebuff Tracker|r: API debug window not available.")
        end
        return
    end

    if msg == "debug" then
        if addon.UpdateTrackedAuras then
            addon:UpdateTrackedAuras()
        end
            print("|cff00ccffDebuff Tracker|r --- DEBUG ---")
        if addon.TrackerFrame then
            print("  TrackerFrame: shown=" .. tostring(addon.TrackerFrame:IsShown())
                .. " visible=" .. tostring(addon.TrackerFrame:IsVisible())
                .. " alpha=" .. tostring(addon.TrackerFrame:GetAlpha())
                .. " strata=" .. tostring(addon.TrackerFrame:GetFrameStrata()))
            local p, _, rp, px, py = addon.TrackerFrame:GetPoint()
            print("  Position: " .. tostring(p) .. " " .. tostring(rp) .. " x=" .. tostring(px) .. " y=" .. tostring(py))
        else
            print("  TrackerFrame: NOT CREATED")
        end
        if addon.GetTrackerDebugInfo then
            local info = addon:GetTrackerDebugInfo()
            print("  Buttons: firstShown=" .. tostring(info.buttonShown)
                .. " firstAlpha=" .. tostring(info.buttonAlpha)
                .. " firstSpell=" .. tostring(info.firstSpell)
                .. " firstIcon=" .. tostring(info.firstIcon)
                .. " firstTexture=" .. tostring(info.firstTexture))
            print("  AuraNow: spell=" .. tostring(info.auraSpell)
                .. " icon=" .. tostring(info.auraIcon)
                .. " duration=" .. tostring(info.firstDuration)
                .. " scanCount=" .. tostring(info.scanCount))
            print("  LastUpdate: reason=" .. tostring(info.lastUpdateReason)
                .. " auraCount=" .. tostring(info.lastAuraCount)
                .. " time=" .. tostring(info.lastUpdateTime))
            if info.counters then
                print("  Events: unitAura=" .. tostring(info.counters.unitAura)
                    .. " enterCombat=" .. tostring(info.counters.enterCombat)
                    .. " leaveCombat=" .. tostring(info.counters.leaveCombat)
                    .. " combatPoll=" .. tostring(info.counters.combatPoll))
            end
            if info.lastCombat then
                print("  LastCombat: shown=" .. tostring(info.lastCombat.buttonShown)
                    .. " alpha=" .. tostring(info.lastCombat.buttonAlpha)
                    .. " spell=" .. tostring(info.lastCombat.firstSpell)
                    .. " icon=" .. tostring(info.lastCombat.firstIcon)
                    .. " texture=" .. tostring(info.lastCombat.firstTexture)
                    .. " reason=" .. tostring(info.lastCombat.lastUpdateReason)
                    .. " auraCount=" .. tostring(info.lastCombat.lastAuraCount))
            else
                print("  LastCombat: none")
            end
        end
            print("|cff00ccffDebuff Tracker|r --- END ---")
            print("|cff00ccffDebuff Tracker|r: Use |cff00ff00/dba scan|r for aura scan details, |cff00ff00/dba cache|r for cache details, and |cff00ff00/dba api|r for the API panel.")
        return
    end

    -- Default action: toggle config window
    addon:ToggleConfig()
end

function addon:GetDefaultSettings()
    return CopyTable(defaults)
end

function addon:ResetConfigDefaults()
    if not addon.db then
        return
    end

    addon.db.auraFilter = defaults.auraFilter

    if addon.UpdateTrackedAuras then
        addon:UpdateTrackedAuras("reset-config-defaults")
    end
    if addon.RefreshConfigFrame then
        addon:RefreshConfigFrame()
    end

    print("|cff00ccffDebuff Tracker|r: Panel settings reset to defaults.")
end

function addon:ResetAllSettings()
    if not addon.db then
        return
    end

    ApplyDefaultsToDb(addon.db)

    if addon.RefreshTrackerLayout then
        addon:RefreshTrackerLayout()
    end
    if addon.ResetTrackerPosition then
        addon:ResetTrackerPosition()
    end
    if addon.UpdateTrackerLock then
        addon:UpdateTrackerLock()
    end
    if addon.UpdateTrackedAuras then
        addon:UpdateTrackedAuras("reset-defaults")
    end
    if addon.RefreshConfigFrame then
        addon:RefreshConfigFrame()
    end

    print("|cff00ccffDebuff Tracker|r: Settings reset to defaults.")
end

function addon:ToggleConfig()
    if addon.ConfigFrame and addon.ConfigFrame:IsShown() then
        addon.ConfigFrame:Hide()
    else
        local ok, err = pcall(function() addon:OpenConfig() end)
        if not ok then
            print("|cff00ccffDebuff Tracker|r: Error opening config: " .. tostring(err))
        end
    end
end
