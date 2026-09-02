-- ReadyCheckLoadouts.lua
local addonName, RCL = ...

-- ============================================================
-- Settings & Database
-- ============================================================
local DEFAULT_SETTINGS = {
    showInRaid       = true,
    showInDungeon    = true,
    sayLoadout       = true,
    sayRunes         = false,
    showLootSpec     = true,
    showDurability   = true,     -- NEW: show gear durability on the frame
    sayDurability    = false,    -- NEW: announce durability in chat
    showPoisons      = true,     -- warn Rogues when a weapon poison is missing
    outputChannel    = "SAY",    -- NEW: chat channel for announcements
    showConsumables    = true,    -- show tracked consumables on the ready-check frame
    consumablesLowOnly = false,   -- only list consumables that are low or missing
    autoSwitch       = false,
    dungeonPresets   = {},       -- [DungeonID] = ConfigID
    retiredDungeonPresets = {},  -- [DungeonID] = ConfigID, from seasons no longer in the pool
    trackedConsumables = {},     -- list of { id = <number>, threshold = <number> }
    frameScale       = 1.0,      -- NEW
    frameOpacity     = 1.0,      -- NEW
    lockFrame        = false,    -- NEW
    -- framePoint is added dynamically when the user drags the window
}

local settings = CopyTable(DEFAULT_SETTINGS)
local myCharKey  -- "Name - Realm"; set at PLAYER_LOGIN by InitConsumableStore

-- Default low-supply warning threshold applied to a newly tracked consumable.
local DEFAULT_CONSUMABLE_THRESHOLD = 10

local function LoadSettings()
    ReadyCheckLoadoutsDB = ReadyCheckLoadoutsDB or {}
    for k in pairs(DEFAULT_SETTINGS) do
        if ReadyCheckLoadoutsDB[k] ~= nil then
            settings[k] = ReadyCheckLoadoutsDB[k]
        end
    end
    -- framePoint is not in DEFAULT_SETTINGS (nil values aren't iterable),
    -- so pull it explicitly when present.
    if type(ReadyCheckLoadoutsDB.framePoint) == "table" then
        settings.framePoint = ReadyCheckLoadoutsDB.framePoint
    end
    -- One live reference; SavedVariables serializes this at logout.
    ReadyCheckLoadoutsDB = settings
end

-- Account-wide consumable store, keyed by character ("Name - Realm").
-- Each character's tracked list is its profile; this is what enables
-- "Copy from <character>" across the account.
local function InitConsumableStore()
    ReadyCheckLoadoutsAccountDB = ReadyCheckLoadoutsAccountDB or {}
    ReadyCheckLoadoutsAccountDB.consumablesByCharacter = ReadyCheckLoadoutsAccountDB.consumablesByCharacter or {}
    local store = ReadyCheckLoadoutsAccountDB.consumablesByCharacter
    myCharKey = (UnitName("player") or "Unknown") .. " - " .. (GetRealmName() or "Unknown")
    if store[myCharKey] == nil then
        -- Migrate this character's existing per-character list (or start empty).
        store[myCharKey] = settings.trackedConsumables or {}
    end
    -- Point the live working list at the account-backed entry, so all
    -- existing code (manager, bag scan, ready-check block) stays unchanged.
    settings.trackedConsumables = store[myCharKey]
end

-- ============================================================
-- Data Constants
-- ============================================================
-- The Mythic+ pool is read live from the client rather than hardcoded per season.
-- C_ChallengeMode.GetMapTable() returns this season's challenge map ids, and
-- GetMapUIInfo returns the instance mapID as its sixth value (added in patch 11.2.0).
-- That mapID is the same number GetInstanceInfo reports as its eighth return, which is
-- the key dungeonPresets is stored under, so no id translation is needed. Verified in
-- 12.1: Ruby Life Pools 2521 and Murder Row 2813 sit alongside the previously
-- client-verified Algeth'ar Academy 2526 and Magisters' Terrace 2811.
--
-- May return an empty list: GetMapTable is not populated until CHALLENGE_MODE_MAPS_UPDATE
-- fires after login. Both callers build lazily (menu open, tooltip show), so an early
-- empty result resolves itself, but callers must still handle it.
local function GetSeasonalDungeons()
    local list, seen = {}, {}
    for _, mapChallengeModeID in ipairs(C_ChallengeMode.GetMapTable() or {}) do
        local name, _, _, _, _, instanceID = C_ChallengeMode.GetMapUIInfo(mapChallengeModeID)
        -- Megadungeon wings are two challenge maps sharing one instanceID. Keep the first
        -- so a single preset key never gets two rows in the dropdown.
        if name and instanceID and not seen[instanceID] then
            seen[instanceID] = true
            list[#list + 1] = { name = name, id = instanceID }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Presets assigned in an earlier season are keyed by instance ids no longer in the pool,
-- so the dropdown can never reach them again. Move them aside once per session rather
-- than deleting them, so nothing the user configured is destroyed silently.
local retiredPresetsChecked = false
local function RetireStalePresets(currentList)
    if retiredPresetsChecked or #currentList == 0 then return end
    retiredPresetsChecked = true

    local active = {}
    for _, dungeon in ipairs(currentList) do active[dungeon.id] = true end

    settings.retiredDungeonPresets = settings.retiredDungeonPresets or {}
    local moved = 0
    for instanceID, configID in pairs(settings.dungeonPresets) do
        if not active[instanceID] then
            settings.retiredDungeonPresets[instanceID] = configID
            settings.dungeonPresets[instanceID] = nil
            moved = moved + 1
        end
    end
    if moved > 0 then
        print(("|cff00ccff[RCL]|r Retired %d dungeon preset%s from a previous season."):format(
            moved, moved == 1 and "" or "s"))
    end
end

local MPLUS_DIFFICULTY  = DifficultyUtil.ID.MythicKeystone
local MYTHIC_DIFFICULTY = DifficultyUtil.ID.DungeonMythic
local function IsMythicDifficulty(diffID)
    return diffID == MPLUS_DIFFICULTY or diffID == MYTHIC_DIFFICULTY
end

local CHANNEL_OPTIONS = {
    { value = "GROUP",         label = "Smart (auto)" },
    { value = "SAY",           label = "/say" },
    { value = "YELL",          label = "/yell" },
    { value = "PARTY",         label = "/party" },
    { value = "RAID",          label = "/raid" },
    { value = "INSTANCE_CHAT", label = "/instance" },
    { value = "EMOTE",         label = "/emote" },
}

local function GetChannelLabel(value)
    for _, ch in ipairs(CHANNEL_OPTIONS) do
        if ch.value == value then return ch.label end
    end
    return "/say"
end

local function GetActiveChannel()
    local ch = settings.outputChannel or "SAY"
    if ch == "GROUP" then
        if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
        if IsInRaid() then return "RAID" end
        if IsInGroup() then return "PARTY" end
        return "SAY"
    end
    return ch
end

local function StripColor(s)
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Announce(text)
    if not text or text == "" then return end
    SendChatMessage(StripColor(text), GetActiveChannel())
end

-- ============================================================
-- Main Display Frame
-- ============================================================
local frame = CreateFrame("Frame", "RCLMainFrame", UIParent, "BackdropTemplate")
frame:SetSize(420, 150)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)
frame:SetScript("OnDragStart", function(self)
    if not settings.lockFrame then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    settings.framePoint = { point = point, relPoint = relPoint, x = x, y = y }
end)
frame:SetFrameStrata("HIGH")
frame:Hide()

frame:SetBackdrop({
    bgFile   = "Interface/DialogFrame/UI-DialogBox-Background",
    edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 32,
    insets   = { left = 11, right = 12, top = 12, bottom = 11 },
})

local titleBar = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
titleBar:SetPoint("TOP", frame, "TOP", 0, -18)
titleBar:SetText("Ready Check: Your Loadouts")

local specIcon = frame:CreateTexture(nil, "ARTWORK")
specIcon:SetSize(40, 40)
specIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 22, -56)

local specLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
specLabel:SetPoint("TOPLEFT", specIcon, "TOPRIGHT", 10, 0)

local gearLoadoutLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
gearLoadoutLabel:SetTextColor(0.8, 0.8, 0.8)
gearLoadoutLabel:SetPoint("TOPLEFT", specLabel, "BOTTOMLEFT", 0, -5)

local talentLoadoutLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
talentLoadoutLabel:SetTextColor(0.8, 0.8, 0.8)
talentLoadoutLabel:SetPoint("TOPLEFT", gearLoadoutLabel, "BOTTOMLEFT", 0, -2)

local lootSpecLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
lootSpecLabel:SetTextColor(0.8, 0.8, 0.8)
lootSpecLabel:SetPoint("TOPLEFT", talentLoadoutLabel, "BOTTOMLEFT", 0, -2)
lootSpecLabel:Hide()

local durabilityLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
durabilityLabel:SetTextColor(0.8, 0.8, 0.8)
durabilityLabel:SetPoint("TOPLEFT", lootSpecLabel, "BOTTOMLEFT", 0, -2)
durabilityLabel:Hide()

local runeLoadoutLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
runeLoadoutLabel:SetTextColor(0.8, 0.8, 0.8)
runeLoadoutLabel:SetPoint("TOPLEFT", durabilityLabel, "BOTTOMLEFT", 0, -15)
runeLoadoutLabel:Hide()

local poisonLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
poisonLabel:SetTextColor(0.8, 0.8, 0.8)
poisonLabel:SetPoint("TOPLEFT", runeLoadoutLabel, "BOTTOMLEFT", 0, -15)
poisonLabel:Hide()

local consumablesLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
consumablesLabel:SetTextColor(0.8, 0.8, 0.8)
consumablesLabel:SetPoint("TOPLEFT", poisonLabel, "BOTTOMLEFT", 0, -15)
consumablesLabel:SetJustifyH("LEFT")
consumablesLabel:Hide()

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
closeBtn:SetScript("OnClick", function() frame:Hide() end)

-- Apply scale/opacity/position from saved settings. Called after LoadSettings()
-- because the frame is created at file-parse time before SavedVariables exist.
local function ApplyFrameAppearance()
    frame:SetScale(settings.frameScale or 1.0)
    frame:SetAlpha(settings.frameOpacity or 1.0)
    local fp = settings.framePoint
    if type(fp) == "table" and fp.point then
        frame:ClearAllPoints()
        frame:SetPoint(fp.point, UIParent, fp.relPoint or fp.point, fp.x or 0, fp.y or 0)
    end
end

local function ResetFramePosition()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER")
    settings.framePoint = nil
end

-- ============================================================
-- Tooltip Helpers & API Scanners
-- ============================================================
local function AddSimpleTooltip(uiFrame, title, description)
    uiFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
        if description then
            GameTooltip:AddLine(description, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    uiFrame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

local function GetWeaponEnchantText(slotID)
    local tooltipData = C_TooltipInfo.GetInventoryItem("player", slotID)
    if tooltipData then
        for _, line in ipairs(tooltipData.lines) do
            if line.type == Enum.TooltipDataLineType.ItemEnchantmentPermanent then
                if line.leftText then
                    return (line.leftText:gsub("Enchanted: ", ""))
                end
            end
        end
    end
    -- Returns nil when no permanent enchant is present (DK runes are permanent enchants;
    -- GetWeaponEnchantInfo() only sees temporary enchants and must NOT be used as the gate.)
    return nil
end

local function GetLootSpecText()
    local lootSpecID = GetLootSpecialization()
    if lootSpecID == 0 then
        return "Active Spec"
    end
    local _, name = GetSpecializationInfoByID(lootSpecID)
    return name or "Unknown"
end

-- Inventory slots that can have durability (armor + weapons).
-- Used by GetGearDurability for iteration and by the equipment-change event handler
-- to filter out swaps to slots that can't affect durability (rings, trinkets, neck, shirt, tabard).
local DURABILITY_SLOTS = {
    [1]  = true, -- head
    [3]  = true, -- shoulder
    [5]  = true, -- chest
    [6]  = true, -- waist
    [7]  = true, -- legs
    [8]  = true, -- feet
    [9]  = true, -- wrist
    [10] = true, -- hands
    [15] = true, -- back
    [16] = true, -- main hand
    [17] = true, -- off hand
}

-- Returns averagePct, lowestPct -- or nil if the character has no durable items equipped.
local function GetGearDurability()
    local totalCur, totalMax = 0, 0
    local minPct = 100
    local count = 0
    for slot in pairs(DURABILITY_SLOTS) do
        local cur, max = GetInventoryItemDurability(slot)
        if cur and max and max > 0 then
            totalCur = totalCur + cur
            totalMax = totalMax + max
            local pct = (cur / max) * 100
            if pct < minPct then minPct = pct end
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return (totalCur / totalMax) * 100, minPct
end

local function DurabilityColor(pct)
    if pct > 75 then
        return "|cff00ff00"
    elseif pct > 25 then
        return "|cffffff00"
    else
        return "|cffff0000"
    end
end

-- Returns the formatted durability label text, or nil if the character has no durable items.
-- Centralised so both ShowLoadoutWindow and the live-refresh event handler stay in sync.
local function BuildDurabilityText()
    local avgPct, lowPct = GetGearDurability()
    if not avgPct then return nil end
    return string.format(
        "Durability: %s%d%%|r (lowest: %s%d%%|r)",
        DurabilityColor(avgPct), math.floor(avgPct + 0.5),
        DurabilityColor(lowPct), math.floor(lowPct + 0.5)
    )
end

-- ============================================================
-- Display Logic
-- ============================================================
local function GetLoadoutInfo()
    local specIndex = C_SpecializationInfo.GetSpecialization()
    if not specIndex then return "No Spec", nil, "No Set", "Unknown", nil end

    local specID, specName, _, specIconID = C_SpecializationInfo.GetSpecializationInfo(specIndex)

    local talentName = "Unknown"
    if specID and C_ClassTalents.GetLastSelectedSavedConfigID then
        local configID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        if configID then
            local info = C_Traits.GetConfigInfo(configID)
            if info then talentName = info.name end
        else
            talentName = "Unsaved / Starter Build"
        end
    end

    local gearName = "No Set"
    if C_EquipmentSet then
        for _, id in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
            local name, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(id)
            if isEquipped then gearName = name break end
        end
    end

    return specName, specIconID, gearName, talentName, specID
end

local BuildConsumablesText
-- ============================================================
-- Rogue Weapon Poisons
-- ============================================================
-- Aura spell ids for every current weapon poison, split by category because a Rogue
-- runs one lethal and one non-lethal at a time (Dragon-Tempered Blades permits a
-- second of each; this display names whichever it finds first per category). The
-- ability and its hour-long self-buff share one spell id. 381664/381637 are confirmed
-- against the Warcraft Wiki 12.0.1 trackable-aura list; the five older ids predate
-- Dragonflight and have been stable for years. A wrong id here produces a false
-- "Missing!" warning, so every id must be scan-verified in-client before release.
local LETHAL_POISON_IDS    = { 2823, 315584, 8679, 381664 } -- Deadly, Instant, Wound, Amplifying
local NONLETHAL_POISON_IDS = { 3408, 5761, 381637 }         -- Crippling, Numbing, Atrophic

-- Returns the localized name of the first active poison in the list (nil if none is
-- active), plus whether the player knows at least one poison in the list at all.
-- Knowledge gates the warning: a spec or build without a poison category should not
-- warn about it, and non-Rogues are filtered before this is ever called.
local function GetActivePoison(spellIDs)
    local known = false
    for _, spellID in ipairs(spellIDs) do
        if IsPlayerSpell(spellID) then
            known = true
            local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
            if aura and aura.name then
                return aura.name, true
            end
        end
    end
    return nil, known
end

-- Returns the formatted poison line for the ready check window, or nil when the
-- player knows no poisons at all (nothing worth warning about).
local function BuildPoisonText()
    local lethalName, lethalKnown       = GetActivePoison(LETHAL_POISON_IDS)
    local nonlethalName, nonlethalKnown = GetActivePoison(NONLETHAL_POISON_IDS)
    if not lethalKnown and not nonlethalKnown then return nil end

    local missing = "|cffff0000Missing!|r"
    if lethalKnown and nonlethalKnown then
        return "Poisons: " .. (lethalName or missing) .. " / " .. (nonlethalName or missing)
    end
    return "Poison: " .. (lethalName or nonlethalName or missing)
end

local function ShowLoadoutWindow(overrideWarningText, cachedDiffID, cachedInstID)
    local specName, specIconID, gearName, talentName, specID = GetLoadoutInfo()

    local diffID, instID = cachedDiffID, cachedInstID
    if not diffID then
        local _, _, d, _, _, _, _, i = GetInstanceInfo()
        diffID, instID = d, i
    end
    local isMythic = IsMythicDifficulty(diffID)
    local presetID = settings.dungeonPresets[instID]

    local warningText = overrideWarningText or ""
    local intendedTalentName = talentName

    if isMythic and presetID and warningText == "" and specID then
        local currentID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
        if currentID ~= presetID then
            local pInfo = C_Traits.GetConfigInfo(presetID)
            local pName = pInfo and pInfo.name or "Unknown"
            warningText = "\n|cffff0000[WRONG LOADOUT! Need: " .. pName .. "]|r"
        end
    end

    if overrideWarningText and overrideWarningText ~= "" then
        local switchedName = overrideWarningText:match("%[Auto%-Switched to: (.-)%]")
        if switchedName then intendedTalentName = switchedName end
    end

    if specIconID then specIcon:SetTexture(specIconID) end
    specLabel:SetText(specName)
    gearLoadoutLabel:SetText("Gear: " .. gearName)
    talentLoadoutLabel:SetText("Talents: " .. talentName .. warningText)

    local frameHeight = 150

    if settings.showLootSpec then
        lootSpecLabel:SetText("Loot Spec: " .. GetLootSpecText())
        lootSpecLabel:Show()
        frameHeight = frameHeight + 20
    else
        lootSpecLabel:Hide()
    end

    local durabilityTextOutput = ""
    if settings.showDurability then
        durabilityTextOutput = BuildDurabilityText() or ""
        if durabilityTextOutput ~= "" then
            durabilityLabel:SetText(durabilityTextOutput)
            durabilityLabel:Show()
            frameHeight = frameHeight + 20
        else
            durabilityLabel:Hide()
        end
    else
        durabilityLabel:Hide()
    end

    local runeTextOutput = ""
    local _, classFilename = UnitClass("player")
    if classFilename == "DEATHKNIGHT" then
        -- GetWeaponEnchantText returns nil when no permanent enchant is found.
        -- We use its return value to both detect and name the rune; GetWeaponEnchantInfo()
        -- is intentionally not used here because it only reports temporary enchants.
        local mhRuneName = GetWeaponEnchantText(16)
        local mhRune = mhRuneName or "|cffff0000Missing!|r"
        if GetInventoryItemID("player", 17) then
            local ohRuneName = GetWeaponEnchantText(17)
            local ohRune = ohRuneName or "|cffff0000Missing!|r"
            runeTextOutput = "Runes: " .. mhRune .. " / " .. ohRune
        else
            runeTextOutput = "Rune: " .. mhRune
        end
        runeLoadoutLabel:SetText(runeTextOutput)
        runeLoadoutLabel:Show()
        frameHeight = frameHeight + 20
    else
        runeLoadoutLabel:Hide()
    end

    if settings.showPoisons and classFilename == "ROGUE" then
        local poisonText = BuildPoisonText()
        if poisonText then
            poisonLabel:SetText(poisonText)
            poisonLabel:Show()
            frameHeight = frameHeight + 20
        else
            poisonLabel:Hide()
        end
    else
        poisonLabel:Hide()
    end

    if settings.showConsumables then
        local consumablesText = BuildConsumablesText()
        if consumablesText then
            consumablesLabel:SetText(consumablesText)
            consumablesLabel:Show()
            frameHeight = frameHeight + consumablesLabel:GetStringHeight() + 27
        else
            consumablesLabel:Hide()
        end
    else
        consumablesLabel:Hide()
    end

    frame:SetHeight(frameHeight)

    if settings.sayLoadout then
        Announce("Talents: " .. intendedTalentName)
    end

    if settings.sayDurability and durabilityTextOutput ~= "" then
        Announce(durabilityTextOutput)
    end

    if settings.sayRunes and classFilename == "DEATHKNIGHT" and runeTextOutput ~= "" then
        Announce(runeTextOutput)
    end

    -- (Phase 4: announce low consumables here, gated on settings.sayConsumables)

    frame:Show()
end

-- ============================================================
-- Options Frame (lazy-built on first /rcl)
-- ============================================================
local optionsFrame
local raidCheckbox, dungeonCheckbox, sayCheckbox, sayRunesCheckbox, lootSpecCheckbox, autoCheckbox
local durabilityCheckbox, sayDurabilityCheckbox, lockFrameCheckbox, consumablesCheckbox, consumablesLowCheckbox
local poisonCheckbox
local scaleSlider, opacitySlider, channelDropdown

local function UpdateChannelDropdownText()
    if channelDropdown then
        channelDropdown:SetText(GetChannelLabel(settings.outputChannel))
    end
end

-- Forward declarations for the Tracked Consumables manager (Phase 2 UI). The button created in
-- EnsureOptionsFrame below and the /rcl handler need these names in scope, but the actual bodies
-- live AFTER the consumable engine (they call ConsumableName/ConsumableCount/ConsumableColor/
-- UntrackConsumable, which aren't lexically visible until then). Declared here, assigned later.
local EnsureConsumablesFrame, UpdateConsumablesDisplay

local function EnsureOptionsFrame()
    if optionsFrame then return end
    optionsFrame = CreateFrame("Frame", "RCLOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(580, 552)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:SetClampedToScreen(true)
    optionsFrame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local optBG = optionsFrame:CreateTexture(nil, "BORDER")
    optBG:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 12, -12)
    optBG:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -12, 12)
    optBG:SetColorTexture(0.05, 0.05, 0.06, 0.95)

    local optionsCloseBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    optionsCloseBtn:SetPoint("TOPRIGHT", optionsFrame, "TOPRIGHT", -4, -4)
    optionsCloseBtn:SetScript("OnClick", function() optionsFrame:Hide() end)

    local function CreateCheck(labelText, relativeFrame, offset)
        local cb = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", relativeFrame, "BOTTOMLEFT", 0, offset)
        local fs = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", cb, "RIGHT", 8, 0)
        fs:SetText(labelText)
        return cb
    end

    local function CreateSectionHeader(text, relativeFrame, offset)
        local h = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        h:SetPoint("TOPLEFT", relativeFrame, "BOTTOMLEFT", -4, offset)
        h:SetText(text)
        h:SetTextColor(1, 0.82, 0)
        return h
    end

    -- Suffix every slider name so we can grab Low/High/Text via _G
    local sliderCounter = 0
    local function CreateSlider(parent, anchorFrame, offsetX, offsetY, label, minVal, maxVal, step, currentVal, formatFn, onChange)
        sliderCounter = sliderCounter + 1
        local name = "RCLSlider" .. sliderCounter
        local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
        s:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", offsetX, offsetY)
        s:SetWidth(170)
        s:SetMinMaxValues(minVal, maxVal)
        s:SetValueStep(step)
        s:SetObeyStepOnDrag(true)
        s:SetValue(currentVal)
        _G[name .. "Low"]:SetText(tostring(minVal))
        _G[name .. "High"]:SetText(tostring(maxVal))
        local textRegion = _G[name .. "Text"]
        textRegion:SetText(label .. ": " .. formatFn(currentVal))
        s:SetScript("OnValueChanged", function(self, value)
            textRegion:SetText(label .. ": " .. formatFn(value))
            onChange(value)
        end)
        return s
    end

    local optTitle = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    optTitle:SetPoint("TOP", optionsFrame, "TOP", 0, -18)
    optTitle:SetText("ReadyCheck Loadouts Options")

    -- Two-column layout. Each column's chain of items anchors off the previous item in that
    -- column as before; the FIRST section header in each column anchors to its column's root
    -- (an invisible 1x1 frame) so the two columns are independent.
    local col1Anchor = CreateFrame("Frame", nil, optionsFrame)
    col1Anchor:SetSize(1, 1)
    col1Anchor:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 24, -50)

    local col2Anchor = CreateFrame("Frame", nil, optionsFrame)
    col2Anchor:SetSize(1, 1)
    col2Anchor:SetPoint("TOPLEFT", optionsFrame, "TOPLEFT", 304, -50)

    -- === Column 1: Display ===
    local displayHeader = CreateSectionHeader("Display", col1Anchor, -6)

    raidCheckbox = CreateCheck("Show window during Raid", displayHeader, -6)
    raidCheckbox:SetScript("OnClick", function(self) settings.showInRaid = self:GetChecked() end)
    AddSimpleTooltip(raidCheckbox, "Raid Ready Check", "Displays the loadout window when a ready check fires inside a raid instance.")

    dungeonCheckbox = CreateCheck("Show window during Dungeon", raidCheckbox, -10)
    dungeonCheckbox:SetScript("OnClick", function(self) settings.showInDungeon = self:GetChecked() end)
    AddSimpleTooltip(dungeonCheckbox, "Dungeon Ready Check", "Displays the loadout window when a ready check fires inside a dungeon instance.")

    lootSpecCheckbox = CreateCheck("Show Loot Specialization", dungeonCheckbox, -10)
    lootSpecCheckbox:SetScript("OnClick", function(self) settings.showLootSpec = self:GetChecked() end)
    AddSimpleTooltip(lootSpecCheckbox, "Loot Specialization", "Displays your active loot specialization on the ready check window. Shows 'Active Spec' if you haven't set a separate loot spec.")

    durabilityCheckbox = CreateCheck("Show Gear Durability", lootSpecCheckbox, -10)
    durabilityCheckbox:SetScript("OnClick", function(self) settings.showDurability = self:GetChecked() end)
    AddSimpleTooltip(durabilityCheckbox, "Gear Durability", "Displays your average gear durability percentage (and the lowest single item) on the ready check window. Color-coded green/yellow/red.")

    poisonCheckbox = CreateCheck("Warn on missing Poisons (Rogue Only)", durabilityCheckbox, -10)
    poisonCheckbox:SetScript("OnClick", function(self) settings.showPoisons = self:GetChecked() end)
    AddSimpleTooltip(poisonCheckbox, "Weapon Poisons", "Shows your active lethal and non-lethal weapon poisons on the ready check window, with a red warning when one is missing. Rogues only; other classes never see the line.")

    -- === Column 1: Announcements ===
    local sayHeader = CreateSectionHeader("Announcements", poisonCheckbox, -16)

    sayCheckbox = CreateCheck("Output loadout in chat", sayHeader, -6)
    sayCheckbox:SetScript("OnClick", function(self) settings.sayLoadout = self:GetChecked() end)
    AddSimpleTooltip(sayCheckbox, "Announce Loadout", "Announces your active talent loadout name so your group can see it.")

    sayRunesCheckbox = CreateCheck("Output Runes in chat (DK Only)", sayCheckbox, -10)
    sayRunesCheckbox:SetScript("OnClick", function(self) settings.sayRunes = self:GetChecked() end)
    AddSimpleTooltip(sayRunesCheckbox, "Announce Runes", "Announces your active Runeforge enchants when a ready check fires.")

    sayDurabilityCheckbox = CreateCheck("Output Gear Durability in chat", sayRunesCheckbox, -10)
    sayDurabilityCheckbox:SetScript("OnClick", function(self) settings.sayDurability = self:GetChecked() end)
    AddSimpleTooltip(sayDurabilityCheckbox, "Announce Durability", "Announces your average gear durability percentage when a ready check fires.")

    -- Channel dropdown (label fits beside the dropdown in this column width)
    local channelLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    channelLabel:SetPoint("TOPLEFT", sayDurabilityCheckbox, "BOTTOMLEFT", 4, -14)
    channelLabel:SetText("Chat channel:")

    channelDropdown = CreateFrame("DropdownButton", "RCLChannelDropdown", optionsFrame, "WowStyle1DropdownTemplate")
    channelDropdown:SetPoint("LEFT", channelLabel, "RIGHT", 10, 0)
    channelDropdown:SetWidth(160)
    channelDropdown:SetText(GetChannelLabel(settings.outputChannel))
    channelDropdown:SetupMenu(function(dropdown, rootDescription)
        for _, ch in ipairs(CHANNEL_OPTIONS) do
            rootDescription:CreateRadio(ch.label,
                function() return settings.outputChannel == ch.value end,
                function()
                    settings.outputChannel = ch.value
                    UpdateChannelDropdownText()
                end)
        end
    end)
    AddSimpleTooltip(channelDropdown, "Output Channel", "Which chat channel announcements are sent to. 'Smart (auto)' picks /instance, /raid, or /party based on your current group, falling back to /say when solo.")

    -- === Column 2: Auto-Switch ===
    local autoHeader = CreateSectionHeader("Auto-Switch", col2Anchor, -6)

    autoCheckbox = CreateCheck("Auto-switch to preset in M+", autoHeader, -6)
    autoCheckbox:SetScript("OnClick", function(self) settings.autoSwitch = self:GetChecked() end)
    AddSimpleTooltip(autoCheckbox, "Auto-Switch Talents", "Automatically changes your talents to the assigned preset for the current Mythic/Mythic+ dungeon when a ready check fires.")

    -- Dungeon presets: label on its own line, dropdown stacked below (label too long to sit
    -- beside a 160-wide dropdown within this column).
    local dropdownLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dropdownLabel:SetPoint("TOPLEFT", autoCheckbox, "BOTTOMLEFT", 4, -14)
    dropdownLabel:SetText("Assign Dungeon Presets:")

    local dungeonDropdown = CreateFrame("DropdownButton", "RCLDungeonDropdown", optionsFrame, "WowStyle1DropdownTemplate")
    dungeonDropdown:SetPoint("TOPLEFT", dropdownLabel, "BOTTOMLEFT", -4, -4)
    dungeonDropdown:SetWidth(180)
    dungeonDropdown:SetText("Configure Presets...")
    dungeonDropdown.UpdateText = function(self) end -- lock text

    dungeonDropdown:SetupMenu(function(dropdown, rootDescription)
        local specIndex = C_SpecializationInfo.GetSpecialization()
        if not specIndex then
            rootDescription:CreateTitle("No specialization active")
            return
        end
        local specID = C_SpecializationInfo.GetSpecializationInfo(specIndex)
        local configs = C_ClassTalents.GetConfigIDsBySpecID(specID)

        local dungeons = GetSeasonalDungeons()
        RetireStalePresets(dungeons)
        if #dungeons == 0 then
            rootDescription:CreateTitle("Dungeon list unavailable")
            return
        end

        for _, dungeon in ipairs(dungeons) do
            local dungeonMenu = rootDescription:CreateButton(dungeon.name)
            if not configs or #configs == 0 then
                dungeonMenu:CreateTitle("No saved loadouts")
            else
                for _, cID in ipairs(configs) do
                    local cInfo = C_Traits.GetConfigInfo(cID)
                    local talentName = cInfo and cInfo.name or "Unnamed"
                    dungeonMenu:CreateRadio(talentName,
                        function() return settings.dungeonPresets[dungeon.id] == cID end,
                        function() settings.dungeonPresets[dungeon.id] = cID end)
                end
            end
        end
    end)

    dungeonDropdown:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Current Dungeon Presets", 1, 0.82, 0)
        local hasPresets = false
        for _, dungeon in ipairs(GetSeasonalDungeons()) do
            local configID = settings.dungeonPresets[dungeon.id]
            if configID then
                local cInfo = C_Traits.GetConfigInfo(configID)
                local talentName = cInfo and cInfo.name or "Unknown"
                GameTooltip:AddDoubleLine(dungeon.name, talentName, 1, 1, 1, 0, 1, 0)
                hasPresets = true
            end
        end
        if not hasPresets then
            GameTooltip:AddLine("No presets assigned.", 0.5, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    dungeonDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- === Column 2: Frame Appearance ===
    local frameHeader = CreateSectionHeader("Frame Appearance", dungeonDropdown, -16)

    scaleSlider = CreateSlider(
        optionsFrame, frameHeader, 18, -22,
        "Scale", 0.5, 2.0, 0.05, settings.frameScale or 1.0,
        function(v) return string.format("%.2f", v) end,
        function(v)
            settings.frameScale = v
            frame:SetScale(v)
        end
    )
    AddSimpleTooltip(scaleSlider, "Frame Scale", "Scales the ready check window. 1.00 is default.")

    opacitySlider = CreateSlider(
        optionsFrame, scaleSlider, 0, -28,
        "Opacity", 0.1, 1.0, 0.05, settings.frameOpacity or 1.0,
        function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end,
        function(v)
            settings.frameOpacity = v
            frame:SetAlpha(v)
        end
    )
    AddSimpleTooltip(opacitySlider, "Frame Opacity", "Sets the transparency of the ready check window. 100% is fully opaque.")

    lockFrameCheckbox = CreateCheck("Lock frame position", opacitySlider, -16)
    lockFrameCheckbox:SetScript("OnClick", function(self) settings.lockFrame = self:GetChecked() end)
    AddSimpleTooltip(lockFrameCheckbox, "Lock Frame", "Prevents the ready check window from being dragged.")

    -- === Column 2: Consumables ===
    local consHeader = CreateSectionHeader("Consumables", lockFrameCheckbox, -16)

    consumablesCheckbox = CreateCheck("Show Tracked Consumables", consHeader, -8)
    consumablesCheckbox:SetScript("OnClick", function(self) settings.showConsumables = self:GetChecked() end)
    AddSimpleTooltip(consumablesCheckbox, "Tracked Consumables", "Shows your tracked consumables and their counts on the ready check window, color-coded green/yellow/red.")

    consumablesLowCheckbox = CreateCheck("Only show low/missing", consumablesCheckbox, -10)
    consumablesLowCheckbox:SetScript("OnClick", function(self) settings.consumablesLowOnly = self:GetChecked() end)
    AddSimpleTooltip(consumablesLowCheckbox, "Low/Missing Only", "When checked, the ready check window only lists consumables below their threshold, hiding the ones you have enough of.")

    -- === Bottom buttons ===
    local testBtn = CreateFrame("Button", nil, optionsFrame, "GameMenuButtonTemplate")
    testBtn:SetSize(115, 24)
    testBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 20, 20)
    testBtn:SetText("Test Window")
    testBtn:SetScript("OnClick", function()
        optionsFrame:Hide()
        ShowLoadoutWindow()
    end)
    AddSimpleTooltip(testBtn, "Test Window", "Simulates a ready check to let you preview how your loadout window looks.")

    local resetBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    resetBtn:SetSize(120, 24)
    resetBtn:SetPoint("BOTTOM", optionsFrame, "BOTTOM", 0, 20)
    resetBtn:SetText("Reset Position")
    resetBtn:SetScript("OnClick", function()
        ResetFramePosition()
        print("|cff00ccff[RCL]|r Frame position reset to center.")
    end)
    AddSimpleTooltip(resetBtn, "Reset Position", "Moves the ready check window back to the center of the screen.")

    local clearBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(120, 24)
    clearBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -20, 20)
    clearBtn:SetText("Clear All Presets")
    clearBtn:SetScript("OnClick", function()
        wipe(settings.dungeonPresets)
        if settings.retiredDungeonPresets then wipe(settings.retiredDungeonPresets) end
        print("|cff00ccff[RCL]|r All dungeon presets cleared.")
    end)
    AddSimpleTooltip(clearBtn, "Clear All Presets", "Removes all assigned dungeon talent presets from your database.")

    -- Opens the dedicated Tracked Consumables manager. Sits in column 2 directly under the
    -- Consumables checkboxes, where Frame Appearance leaves empty space below it.
    local consumablesBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    consumablesBtn:SetSize(160, 24)
    consumablesBtn:SetPoint("TOPLEFT", consumablesLowCheckbox, "BOTTOMLEFT", 0, -12)
    consumablesBtn:SetText("Manage Consumables...")
    consumablesBtn:SetScript("OnClick", function()
        EnsureConsumablesFrame()
        UpdateConsumablesDisplay()
        RCLConsumablesFrame:Show()
    end)
    AddSimpleTooltip(consumablesBtn, "Manage Consumables", "Opens the tracked-consumables manager, where you can adjust low-supply thresholds and stop tracking items.")

    -- Hide it initially so the first /rcl toggle works correctly
    optionsFrame:Hide()
end

local function UpdateOptionsDisplay()
    if not optionsFrame then return end
    raidCheckbox:SetChecked(settings.showInRaid)
    dungeonCheckbox:SetChecked(settings.showInDungeon)
    sayCheckbox:SetChecked(settings.sayLoadout)
    sayRunesCheckbox:SetChecked(settings.sayRunes)
    lootSpecCheckbox:SetChecked(settings.showLootSpec)
    durabilityCheckbox:SetChecked(settings.showDurability)
    poisonCheckbox:SetChecked(settings.showPoisons)
    consumablesCheckbox:SetChecked(settings.showConsumables)
    consumablesLowCheckbox:SetChecked(settings.consumablesLowOnly)
    sayDurabilityCheckbox:SetChecked(settings.sayDurability)
    autoCheckbox:SetChecked(settings.autoSwitch)
    lockFrameCheckbox:SetChecked(settings.lockFrame)
    scaleSlider:SetValue(settings.frameScale or 1.0)
    opacitySlider:SetValue(settings.frameOpacity or 1.0)
    UpdateChannelDropdownText()
end

-- ============================================================
-- Events & Controller
-- ============================================================
local eFrame = CreateFrame("Frame")
eFrame:RegisterEvent("ADDON_LOADED")
eFrame:RegisterEvent("READY_CHECK")
eFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
eFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eFrame:RegisterEvent("PLAYER_LOGIN")
eFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        LoadSettings()
        ApplyFrameAppearance()

    elseif event == "PLAYER_LOGIN" then
        InitConsumableStore()

    elseif event == "UPDATE_INVENTORY_DURABILITY" or event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Live-refresh the durability label so it stays accurate if gear takes damage,
        -- gets repaired, or is swapped while the ready check window is open.
        -- PLAYER_EQUIPMENT_CHANGED passes (slot, hasItem); skip slots that can't have durability
        -- to avoid redundant rebuilds during tier/trinket/ring swaps.
        -- UPDATE_INVENTORY_DURABILITY has no slot arg and always indicates a relevant change.
        if event == "PLAYER_EQUIPMENT_CHANGED" and not DURABILITY_SLOTS[arg1] then return end
        if frame:IsShown() and settings.showDurability then
            local text = BuildDurabilityText()
            if text then
                durabilityLabel:SetText(text)
            end
        end

    elseif event == "READY_CHECK" then
        local inInst, instType = IsInInstance()
        local _, _, diffID, _, _, _, _, instID = GetInstanceInfo()
        local isMythic = IsMythicDifficulty(diffID)

        local autoSwitchedText = ""
        if isMythic and settings.autoSwitch and not InCombatLockdown() then
            local presetID = settings.dungeonPresets[instID]
            local specIndex = C_SpecializationInfo.GetSpecialization()
            if presetID and specIndex then
                local specID = C_SpecializationInfo.GetSpecializationInfo(specIndex)
                local currentID = C_ClassTalents.GetLastSelectedSavedConfigID(specID)
                if currentID ~= presetID and C_ClassTalents.CanChangeTalents() then
                    local ok = C_ClassTalents.LoadConfig(presetID, true)
                    local pInfo = C_Traits.GetConfigInfo(presetID)
                    local pName = pInfo and pInfo.name or "Preset"
                    if ok then
                        autoSwitchedText = "\n|cff00ff00[Auto-Switched to: " .. pName .. "]|r"
                    else
                        autoSwitchedText = "\n|cffff0000[Auto-Switch failed — load " .. pName .. " manually]|r"
                        print("|cff00ccff[RCL]|r LoadConfig returned false for preset:", pName)
                    end
                end
            end
        end

        local shouldShow = false
        if instType == "raid"  and settings.showInRaid    then shouldShow = true end
        if instType == "party" and settings.showInDungeon then shouldShow = true end
        if not inInst then shouldShow = true end

        if shouldShow then
            ShowLoadoutWindow(autoSwitchedText, diffID, instID)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        frame:Hide()
        if optionsFrame then optionsFrame:Hide() end
    end
end)

-- ============================================================
-- Consumable Tracking (Phase 1: data + counting engine, no UI)
-- ============================================================

-- Lazy reverse index of itemID -> { label = <category label>, name = <item name>, ids = <set> },
-- built once from RCL.CONSUMABLE_CATALOG and cached in this upvalue. A catalog item now carries an
-- `ids` set (two itemIDs for Midnight crafted Silver+Gold tiers, one for non-crafted/legacy items);
-- EVERY id in that set is mapped to the SAME shared info table, so any tier resolves to the same
-- label, name, and the complete id set.
local catalogIndex
local function GetCatalogInfo(id)
    if not catalogIndex then
        catalogIndex = {}
        for _, category in ipairs(RCL.CONSUMABLE_CATALOG or {}) do
            for _, item in ipairs(category.items or {}) do
                local info = { label = category.label, name = item.name, ids = item.ids }
                for _, tierID in ipairs(item.ids or {}) do
                    catalogIndex[tierID] = info
                end
            end
        end
    end
    local info = catalogIndex[id]
    if info then
        return info.label, info.name, info.ids
    end
    return nil
end

-- Collapse an itemID to a stable identity for deduping. A catalogued item maps to its set's first id
-- (all of its quality tiers share one id set, so every tier collapses to the same key); an
-- uncatalogued id maps to itself. Used by BOTH the bag scan and the tracker so they group the tiers
-- of a catalog item identically.
local function CatalogKey(id)
    local _, _, ids = GetCatalogInfo(id)
    return (ids and ids[1]) or id
end

-- Display name: prefer the curated catalog name, then the live item cache, then a placeholder.
local function ConsumableName(id)
    local _, name = GetCatalogInfo(id)
    if name then return name end
    C_Item.RequestLoadItemDataByID(id)
    local itemName = C_Item.GetItemInfo(id)
    if itemName then return itemName end
    -- Name still unavailable (item not cached on this character, common right after an import). The
    -- load requested above will fire GET_ITEM_INFO_RECEIVED and trigger a redraw once the data
    -- arrives; until then keep showing the "item:id" placeholder.
    return "item:" .. id
end

-- Single source of truth for counts: carried bags only (no bank, no charges, no reagent bank).
-- When the id belongs to a catalog item, sum GetItemCount across EVERY id in its set so a stack
-- split across the Silver and Gold quality tiers is counted once, in full. Uncatalogued ids fall
-- back to a single GetItemCount. The bags-only flags (false, false, false) are identical in both
-- paths.
local function ConsumableCount(id)
    local _, _, ids = GetCatalogInfo(id)
    if ids then
        local total = 0
        for _, tierID in ipairs(ids) do
            total = total + C_Item.GetItemCount(tierID, false, false, false)
        end
        return total
    end
    return C_Item.GetItemCount(id, false, false, false)
end

-- Parallels DurabilityColor but keyed on count vs threshold. Returns (colorEscape, statusWord).
local function ConsumableColor(count, threshold)
    if count == 0 then
        return "|cffff0000", "out"
    elseif count < threshold then
        return "|cffffff00", "low"
    else
        return "|cff00ff00", "ok"
    end
end

-- Index in settings.trackedConsumables that represents the same item as `id`, or nil. Matching is
-- by CatalogKey, so tracking either quality tier of a catalog item resolves to the single existing
-- entry no matter which tier id it was stored under -- no duplicate per catalog item. Uncatalogued
-- ids still match only their exact id. (Storage stays id-based; we do not rewrite saved entries.)
local function FindTrackedIndex(id)
    local key = CatalogKey(id)
    for i, entry in ipairs(settings.trackedConsumables) do
        if CatalogKey(entry.id) == key then return i end
    end
    return nil
end

-- Add or update a tracked consumable, then warm the item cache for its name.
local function TrackConsumable(id, threshold)
    local index = FindTrackedIndex(id)
    if index then
        settings.trackedConsumables[index].threshold = threshold or settings.trackedConsumables[index].threshold or DEFAULT_CONSUMABLE_THRESHOLD
    else
        table.insert(settings.trackedConsumables, {
            id        = id,
            threshold = threshold or DEFAULT_CONSUMABLE_THRESHOLD,
        })
    end
    C_Item.RequestLoadItemDataByID(id)
end

-- Remove a tracked consumable if present. Returns true when something was removed.
local function UntrackConsumable(id)
    local index = FindTrackedIndex(id)
    if index then
        table.remove(settings.trackedConsumables, index)
        return true
    end
    return false
end

-- Shared output for /rcl tracklist and /rcldebug so the two can never drift.
local function PrintTrackedList()
    if #settings.trackedConsumables == 0 then
        print("|cff00ccff[RCL]|r No consumables tracked.")
        return
    end
    for _, entry in ipairs(settings.trackedConsumables) do
        local count = ConsumableCount(entry.id)
        local color, status = ConsumableColor(count, entry.threshold)
        print(string.format("|cff00ccff[RCL]|r %s%s|r: %d / %d (%s)",
            color, ConsumableName(entry.id), count, entry.threshold, status))
    end
end

-- Scan carried bags for consumables (and optionally everything else). Returns a sorted list of
-- { id, count, label }. Discovery only; counts come from ConsumableCount so this and the tracker
-- always agree. includeOther=true also surfaces non-consumable items (e.g. Auto-Hammer).
local function ScanBags(includeOther)
    local seen, found = {}, {}
    local containers = {}
    for bag = 0, NUM_BAG_SLOTS do
        table.insert(containers, bag)
    end
    table.insert(containers, Enum.BagIndex.ReagentBag)
    for _, bag in ipairs(containers) do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local id = C_Container.GetContainerItemID(bag, slot)
            -- Collapse all quality tiers of a catalog item onto ONE row: dedupe by CatalogKey (the
            -- item's first tier id) rather than the raw id, and report the summed ConsumableCount.
            -- A flask carried at both Silver and Gold thus appears once with the combined count;
            -- uncatalogued ids key on themselves and stay individual.
            local key = id and CatalogKey(id)
            if id and not seen[key] then
                local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(id)
                if includeOther or classID == Enum.ItemClass.Consumable then
                    seen[key] = true
                    table.insert(found, {
                        id    = key,
                        count = ConsumableCount(key),
                        label = GetCatalogInfo(key) or "Uncatalogued",
                    })
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.label ~= b.label then return a.label < b.label end
        return ConsumableName(a.id) < ConsumableName(b.id)
    end)
    return found
end

-- Returns the formatted consumables block for the ready check window, or nil when there is nothing
-- to show. Mirrors BuildDurabilityText so ShowLoadoutWindow can treat it the same way. Assigned to
-- the local forward-declared above ShowLoadoutWindow (depends on ConsumableCount/ConsumableColor/
-- ConsumableName/DEFAULT_CONSUMABLE_THRESHOLD, which aren't in scope until here).
function BuildConsumablesText()
    local tracked = settings.trackedConsumables
    if not tracked or #tracked == 0 then return nil end
    local lines = {}
    for _, entry in ipairs(tracked) do
        local threshold = entry.threshold or DEFAULT_CONSUMABLE_THRESHOLD
        local count = ConsumableCount(entry.id)
        local color, status = ConsumableColor(count, threshold)
        if (not settings.consumablesLowOnly) or status ~= "ok" then
            lines[#lines + 1] = ConsumableName(entry.id) .. ": " .. color .. count .. "|r"
        end
    end
    if #lines == 0 then return nil end
    return "Consumables:\n" .. table.concat(lines, "\n")
end

-- ============================================================
-- Consumable Tracking (Phase 2: tracked-consumables manager UI)
-- ============================================================
-- These assign the locals forward-declared above EnsureOptionsFrame. They sit HERE, after the
-- consumable engine, because their bodies call ConsumableName/ConsumableCount/ConsumableColor/
-- UntrackConsumable -- locals not in lexical scope until this point. (Plain `function Name` rather
-- than `local function Name`, so we populate the existing upvalues instead of shadowing them.)

-- Build the manager frame once; no-op on subsequent calls. Styled to match RCLOptionsFrame.
function EnsureConsumablesFrame()
    if RCLConsumablesFrame then return end

    local f = CreateFrame("Frame", "RCLConsumablesFrame", UIParent, "BackdropTemplate")
    f:SetFrameStrata("DIALOG")
    f:SetSize(400, 460)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetResizable(true)
    f:SetResizeBounds(400, 200)
    f:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile     = true, tileSize = 32, edgeSize = 32,
        insets   = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    local consBG = f:CreateTexture(nil, "BORDER")
    consBG:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
    consBG:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    consBG:SetColorTexture(0.05, 0.05, 0.06, 0.95)

    -- Resize grip in the bottom-right corner; dragging it resizes the frame and reflows the rows.
    local resizeGrip = CreateFrame("Button", nil, f)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    resizeGrip:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        UpdateConsumablesDisplay()
    end)

    -- Reflow rows live while dragging so the name column keeps filling the new width.
    f:SetScript("OnSizeChanged", function()
        if UpdateConsumablesDisplay then UpdateConsumablesDisplay() end
    end)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("Tracked Consumables")

    -- "Add from Bags" dropdown: lists carried consumables that aren't tracked yet; picking one
    -- tracks it. Mirrors the options-frame dropdowns (same template + SetupMenu pattern); UpdateText
    -- is locked so the summary label stays "Add from Bags" like the dungeon-preset dropdown.
    local addBagsDropdown = CreateFrame("DropdownButton", "RCLAddBagsDropdown", f, "WowStyle1DropdownTemplate")
    addBagsDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -44)
    addBagsDropdown:SetWidth(180)
    addBagsDropdown:SetText("Add from Bags")
    addBagsDropdown.UpdateText = function(self) end -- lock text
    addBagsDropdown:SetupMenu(function(dropdown, rootDescription)
        local found = ScanBags(false)
        local addedAny = false
        for _, entry in ipairs(found) do
            if FindTrackedIndex(entry.id) == nil then
                rootDescription:CreateButton(ConsumableName(entry.id) .. "  x" .. entry.count, function()
                    TrackConsumable(entry.id)
                    UpdateConsumablesDisplay()
                end)
                addedAny = true
            end
        end
        if not addedAny then
            rootDescription:CreateTitle("Nothing new to add")
        end
    end)

    -- "Add from Catalog" dropdown: the curated quick-add source, sitting beside "Add from Bags".
    -- Each catalog category becomes a submenu, each item a leaf that tracks its canonical id. Same
    -- template + SetupMenu pattern and the same locked UpdateText so the summary stays "Add from Catalog".
    local addCatalogDropdown = CreateFrame("DropdownButton", "RCLAddCatalogDropdown", f, "WowStyle1DropdownTemplate")
    addCatalogDropdown:SetPoint("LEFT", addBagsDropdown, "RIGHT", 8, 0)
    addCatalogDropdown:SetWidth(180)
    addCatalogDropdown:SetText("Add from Catalog")
    addCatalogDropdown.UpdateText = function(self) end -- lock text
    addCatalogDropdown:SetupMenu(function(dropdown, rootDescription)
        for _, category in ipairs(RCL.CONSUMABLE_CATALOG or {}) do
            local submenu = rootDescription:CreateButton(category.label)
            for _, item in ipairs(category.items) do
                submenu:CreateButton(item.name, function()
                    TrackConsumable(item.ids[1])
                    UpdateConsumablesDisplay()
                end)
            end
        end
    end)

    -- "Copy from..." dropdown: a new row below the two Add dropdowns. Lists every other character
    -- with a non-empty saved list; picking one opens a confirm popup that replaces this character's
    -- tracked list with a copy of theirs. Same template + locked-UpdateText pattern as above.
    local copyFromDropdown = CreateFrame("DropdownButton", "RCLCopyFromDropdown", f, "WowStyle1DropdownTemplate")
    copyFromDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -74)
    copyFromDropdown:SetWidth(180)
    copyFromDropdown:SetText("Copy from...")
    copyFromDropdown.UpdateText = function(self) end -- lock text
    copyFromDropdown:SetupMenu(function(dropdown, rootDescription)
        local store = ReadyCheckLoadoutsAccountDB and ReadyCheckLoadoutsAccountDB.consumablesByCharacter
        local addedAny = false
        for key, value in pairs(store or {}) do
            if key ~= myCharKey and type(value) == "table" and #value > 0 then
                rootDescription:CreateButton(key, function()
                    StaticPopup_Show("RCL_COPY_CONSUMABLES", key, nil, { sourceKey = key })
                end)
                addedAny = true
            end
        end
        if not addedAny then
            rootDescription:CreateTitle("No other characters with a saved list")
        end
    end)

    -- Quick-add search: an as-you-type box that lists untracked matches from BOTH the bags scan and
    -- the catalog (the exact two sources the Add dropdowns use), so an item can be added without
    -- opening the long dropdowns. Forward-declared so the result buttons' OnClick closures (built
    -- below) capture this local as an upvalue rather than a nil global -- same pattern as the file's
    -- other forward-declared manager functions.
    local UpdateSearchResults

    -- Search box on the Copy-from row, filling the space to its right. SearchBoxTemplate brings its
    -- own magnifier and clear button; the clear button empties the text and fires OnTextChanged.
    local searchBox = CreateFrame("EditBox", "RCLAddSearchBox", f, "SearchBoxTemplate")
    searchBox:SetHeight(20)
    searchBox:SetPoint("LEFT", copyFromDropdown, "RIGHT", 10, 0)
    searchBox:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    if searchBox.Instructions then
        searchBox.Instructions:SetText("Search bags & catalog")
    end

    -- Results overlay. Top corners pinned (TOPLEFT 16,-100; right edge at -16) so it fills the width
    -- and grows DOWNWARD as its height is set per-update; a literal mid-RIGHT anchor would fight the
    -- TOPLEFT for vertical position, so the top-right corner is pinned instead. Frame level is raised
    -- above the tracked rows and an opaque BORDER texture (inset 2px) blocks rows bleeding through.
    local results = CreateFrame("Frame", "RCLSearchResults", f)
    results:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -100)
    results:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -100)
    results:SetFrameLevel(f:GetFrameLevel() + 10)
    local resultsBG = results:CreateTexture(nil, "BORDER")
    resultsBG:SetPoint("TOPLEFT", results, "TOPLEFT", 2, -2)
    resultsBG:SetPoint("BOTTOMRIGHT", results, "BOTTOMRIGHT", -2, 2)
    resultsBG:SetColorTexture(0.05, 0.05, 0.06, 0.95)
    results:Hide()

    -- Pool of up to 8 result buttons, stacked from the panel top. Each shows an item icon, a
    -- left-justified name, and a right-justified quantity (bag count) or blank. OnClick tracks the
    -- item via the same TrackConsumable + UpdateConsumablesDisplay path the Add dropdowns use, then
    -- re-runs the search so the just-added item drops out of the list.
    results.buttons = {}
    for i = 1, 8 do
        local btn = CreateFrame("Button", nil, results)
        btn:SetHeight(22)
        if i == 1 then
            btn:SetPoint("TOPLEFT", results, "TOPLEFT", 4, -4)
            btn:SetPoint("TOPRIGHT", results, "TOPRIGHT", -4, -4)
        else
            btn:SetPoint("TOPLEFT", results.buttons[i - 1], "BOTTOMLEFT", 0, 0)
            btn:SetPoint("TOPRIGHT", results.buttons[i - 1], "BOTTOMRIGHT", 0, 0)
        end

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(btn)
        hl:SetColorTexture(1, 1, 1, 0.15)

        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetSize(18, 18)
        btn.icon:SetPoint("LEFT", btn, "LEFT", 2, 0)

        btn.qty = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.qty:SetJustifyH("RIGHT")
        btn.qty:SetPoint("RIGHT", btn, "RIGHT", -6, 0)

        btn.name = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        btn.name:SetJustifyH("LEFT")
        btn.name:SetWordWrap(false)
        btn.name:SetPoint("LEFT", btn.icon, "RIGHT", 6, 0)
        btn.name:SetPoint("RIGHT", btn.qty, "LEFT", -6, 0)

        btn:SetScript("OnClick", function(self)
            if self.matchId then
                TrackConsumable(self.matchId)
                UpdateConsumablesDisplay()
                UpdateSearchResults()
            end
        end)

        btn:Hide()
        results.buttons[i] = btn
    end

    -- Rebuild the result list from the current query. Sources and the tracked-skip check mirror the
    -- two Add dropdowns exactly; de-dupe is by CatalogKey, preferring the bag entry so its count shows.
    function UpdateSearchResults()
        local query = strtrim(searchBox:GetText() or ""):lower()
        if query == "" then
            results:Hide()
            return
        end

        local byKey, candidates = {}, {}

        -- Untracked bag consumables, exactly like "Add from Bags": ScanBags returns entries whose .id
        -- is already the CatalogKey, with a summed .count we can surface as the quantity.
        for _, entry in ipairs(ScanBags(false)) do
            if FindTrackedIndex(entry.id) == nil then
                local key = CatalogKey(entry.id)
                if not byKey[key] then
                    local cand = { id = entry.id, name = ConsumableName(entry.id), count = entry.count }
                    byKey[key] = cand
                    candidates[#candidates + 1] = cand
                end
            end
        end

        -- Untracked catalog entries, exactly like "Add from Catalog": walk each category's items and
        -- track item.ids[1]. Only add when the CatalogKey is new, so a bag entry (with its count) wins.
        for _, category in ipairs(RCL.CONSUMABLE_CATALOG or {}) do
            for _, item in ipairs(category.items) do
                local id = item.ids[1]
                if FindTrackedIndex(id) == nil then
                    local key = CatalogKey(id)
                    if not byKey[key] then
                        local cand = { id = id, name = item.name, count = nil }
                        byKey[key] = cand
                        candidates[#candidates + 1] = cand
                    end
                end
            end
        end

        -- Plain-substring name match (1, true => no pattern interpretation).
        local matches = {}
        for _, cand in ipairs(candidates) do
            local nameLower = (cand.name or ""):lower()
            if string.find(nameLower, query, 1, true) then
                matches[#matches + 1] = cand
            end
        end
        table.sort(matches, function(a, b) return (a.name or "") < (b.name or "") end)

        local shown = 0
        for i, btn in ipairs(results.buttons) do
            local cand = matches[i]
            if cand then
                local _, _, _, _, iconID = C_Item.GetItemInfoInstant(cand.id)
                btn.icon:SetTexture(iconID or 134400)
                btn.name:SetText(cand.name)
                btn.qty:SetText(cand.count and ("x" .. cand.count) or "")
                btn.matchId = cand.id
                btn:Show()
                shown = i
            else
                btn.matchId = nil
                btn:Hide()
            end
        end

        if shown == 0 then
            results:Hide()
        else
            results:SetHeight(shown * 22 + 8)
            results:Show()
        end
    end

    -- Hook (not Set) OnTextChanged so SearchBoxTemplate keeps toggling its own clear button and
    -- instructions; our handler just refreshes the results on every keystroke and on clear.
    searchBox:HookScript("OnTextChanged", function() UpdateSearchResults() end)

    -- Column headers (always visible). Each is a mouse-enabled Frame holding a FontString so it
    -- can show a tooltip explaining its column. Anchored to f so they hold position as rows reflow.
    local hItem = CreateFrame("Frame", nil, f)
    hItem:SetSize(60, 14)
    hItem:SetPoint("TOPLEFT", f, "TOPLEFT", 48, -104)
    hItem:EnableMouse(true)
    local hItemText = hItem:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hItemText:SetAllPoints(hItem)
    hItemText:SetJustifyH("LEFT")
    hItemText:SetText("Item")
    hItem:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Item"); GameTooltip:AddLine("The consumable being tracked. Hover a row's icon or name for its full in-game tooltip.", 1, 1, 1, true); GameTooltip:Show() end)
    hItem:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local hQty = CreateFrame("Frame", nil, f)
    hQty:SetSize(90, 14)
    hQty:SetPoint("TOPRIGHT", f, "TOPRIGHT", -124, -104)
    hQty:EnableMouse(true)
    local hQtyText = hQty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hQtyText:SetAllPoints(hQty)
    hQtyText:SetJustifyH("CENTER")
    hQtyText:SetText("Qty on hand")
    hQty:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Qty on Hand"); GameTooltip:AddLine("How many you currently carry, summed across both quality tiers. Green at or above your threshold, yellow below it, red at zero.", 1, 1, 1, true); GameTooltip:Show() end)
    hQty:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local hThreshold = CreateFrame("Frame", nil, f)
    hThreshold:SetSize(72, 14)
    hThreshold:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -104)
    hThreshold:EnableMouse(true)
    local hThresholdText = hThreshold:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hThresholdText:SetAllPoints(hThreshold)
    hThresholdText:SetJustifyH("CENTER")
    hThresholdText:SetText("Threshold")
    hThreshold:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Threshold"); GameTooltip:AddLine("The low-water mark. Your count turns yellow below this number and red at zero. Adjust with the - / + buttons or type a value in the box.", 1, 1, 1, true); GameTooltip:Show() end)
    hThreshold:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f:Hide()
end

-- Render settings.trackedConsumables into a reusable row pool on the frame so repeated refreshes
-- show/hide rows instead of leaking new frames. Each row: name, color-coded count, threshold
-- stepper, and a remove control. Safe to call any time the frame exists.
function UpdateConsumablesDisplay()
    local f = RCLConsumablesFrame
    if not f then return end
    f.rows = f.rows or {}

    local tracked = settings.trackedConsumables

    -- Empty-state hint, created once and toggled with the list.
    if not f.emptyText then
        local et = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        et:SetPoint("CENTER", f, "CENTER", 0, 0)
        et:SetWidth(340)
        et:SetJustifyH("CENTER")
        et:SetText("No consumables tracked yet. Use the Add from Bags or Add from Catalog buttons above, or /rcl track <itemID>.")
        f.emptyText = et
    end

    if #tracked == 0 then
        for _, row in ipairs(f.rows) do row:Hide() end
        f.emptyText:Show()
        return
    end
    f.emptyText:Hide()

    local ROW_HEIGHT = 26

    for i, entry in ipairs(tracked) do
        local row = f.rows[i]
        if not row then
            row = CreateFrame("Frame", nil, f)
            row:SetHeight(ROW_HEIGHT)
            if i == 1 then
                row:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -130)
            else
                row:SetPoint("TOPLEFT", f.rows[i - 1], "BOTTOMLEFT", 0, 0)
            end
            -- Stretch each row to the frame's right edge so widening the window widens the rows.
            row:SetPoint("RIGHT", f, "RIGHT", -16, 0)

            -- Hovering anywhere on the row (icon, name, or count) shows the item tooltip.
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if self.entry then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetItemByID(self.entry.id)
                    GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- Item icon (far left).
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(20, 20)
            row.icon:ClearAllPoints()
            row.icon:SetPoint("LEFT", row, "LEFT", 30, 0)

            -- Item name. Stretches between the icon and the count column; its cross-anchor to
            -- row.count is set below, once that column has been created.
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)

            -- Remove control (far right). Reads row.entry so the pooled handler always
            -- targets whatever item this row currently shows.
            row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.remove:SetSize(24, 22)
            row.remove:ClearAllPoints()
            row.remove:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.remove:SetText("X")
            row.remove:SetScript("OnClick", function()
                if row.entry then
                    UntrackConsumable(row.entry.id)
                    UpdateConsumablesDisplay()
                end
            end)

            -- Threshold stepper: [-] value [+], grouped just left of the remove control.
            row.plus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.plus:SetSize(24, 22)
            row.plus:ClearAllPoints()
            row.plus:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row.plus:SetText("+")
            row.plus:SetScript("OnClick", function()
                local e = row.entry
                if e then
                    e.threshold = (e.threshold or DEFAULT_CONSUMABLE_THRESHOLD) + 1
                    UpdateConsumablesDisplay()
                end
            end)

            -- Typeable threshold field, between the - and + buttons. The steppers still write
            -- row.entry.threshold and refresh; this box also accepts a value typed directly.
            row.thresholdBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.thresholdBox:SetSize(40, 20)
            row.thresholdBox:SetAutoFocus(false)
            row.thresholdBox:SetNumeric(true)
            row.thresholdBox:SetJustifyH("CENTER")
            row.thresholdBox:SetMaxLetters(5)
            row.thresholdBox:SetPoint("RIGHT", row.plus, "LEFT", -6, 0)
            local function CommitThreshold(self)
                local v = tonumber(self:GetText())
                if not v or v < 1 then v = (row.entry and row.entry.threshold) or DEFAULT_CONSUMABLE_THRESHOLD end
                if row.entry then row.entry.threshold = v end
                self:ClearFocus()
                UpdateConsumablesDisplay()
            end
            row.thresholdBox:SetScript("OnEnterPressed", CommitThreshold)
            row.thresholdBox:SetScript("OnEditFocusLost", CommitThreshold)

            row.minus = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.minus:SetSize(24, 22)
            row.minus:SetPoint("RIGHT", row.thresholdBox, "LEFT", -6, 0)
            row.minus:SetText("-")
            row.minus:SetScript("OnClick", function()
                local e = row.entry
                if e then
                    e.threshold = math.max(1, (e.threshold or DEFAULT_CONSUMABLE_THRESHOLD) - 1)
                    UpdateConsumablesDisplay()
                end
            end)

            -- Current count: a fixed-width column anchored only on its right (to the stepper),
            -- so the name absorbs the slack and grows when the frame is widened.
            row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.count:SetWidth(90)
            row.count:SetPoint("RIGHT", row.minus, "LEFT", -8, 0)
            row.count:SetJustifyH("CENTER")

            -- With the count column built, stretch the name between the icon and the count.
            row.name:ClearAllPoints()
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.name:SetPoint("RIGHT", row.count, "LEFT", -8, 0)

            f.rows[i] = row
        end

        row.entry = entry
        local threshold = entry.threshold or DEFAULT_CONSUMABLE_THRESHOLD
        local count = ConsumableCount(entry.id)
        local color = ConsumableColor(count, threshold)

        local _, _, _, _, iconID = C_Item.GetItemInfoInstant(entry.id)
        row.icon:SetTexture(iconID or 134400)
        row.name:SetText(ConsumableName(entry.id))
        row.thresholdBox:SetText(threshold)
        -- ConsumableColor returns a |c color escape; wrap the count to apply it to the FontString.
        row.count:SetText(color .. count .. "|r")
        row:Show()
    end

    -- Park any pooled rows left over from a previously longer list.
    for i = #tracked + 1, #f.rows do
        f.rows[i]:Hide()
    end
end

-- Confirm + apply copying this character's tracked consumables from another character.
StaticPopupDialogs["RCL_COPY_CONSUMABLES"] = {
    text = "Copy consumables from %s?\nThis replaces this character's tracked list.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        local store = ReadyCheckLoadoutsAccountDB and ReadyCheckLoadoutsAccountDB.consumablesByCharacter
        if not (store and data and data.sourceKey and store[data.sourceKey]) then return end
        store[myCharKey] = CopyTable(store[data.sourceKey])
        settings.trackedConsumables = store[myCharKey]   -- repoint the live list at the fresh copy
        if RCLConsumablesFrame and RCLConsumablesFrame:IsShown() then
            UpdateConsumablesDisplay()
        end
        if frame and frame:IsShown() and settings.showConsumables and consumablesLabel then
            local t = BuildConsumablesText()
            if t then consumablesLabel:SetText(t) end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
}

-- When an item's info finishes loading, re-resolve any tracked rows / ready-check text still
-- showing the "item:id" placeholder (common right after copying a list of items this character
-- has not cached yet).
local itemInfoFrame = CreateFrame("Frame")
itemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemInfoFrame:SetScript("OnEvent", function(_, _, itemID)
    if not itemID then return end
    local managerShown = RCLConsumablesFrame and RCLConsumablesFrame:IsShown()
    local displayShown = frame and frame:IsShown() and settings.showConsumables
    if not (managerShown or displayShown) then return end
    if not FindTrackedIndex(itemID) then return end
    if managerShown then UpdateConsumablesDisplay() end
    if displayShown and consumablesLabel then
        local t = BuildConsumablesText()
        if t then consumablesLabel:SetText(t) end
    end
end)

-- ============================================================
-- Slash Commands
-- ============================================================
SLASH_RCLLOADOUTS1 = "/rcl"
SlashCmdList["RCLLOADOUTS"] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" then
        -- Preserve original behavior: bare/whitespace-only /rcl toggles the options frame.
        EnsureOptionsFrame()
        if optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            UpdateOptionsDisplay()
            optionsFrame:Show()
        end

    elseif cmd == "track" then
        local idStr, threshStr = rest:match("^(%S*)%s*(.-)$")
        local id = tonumber(idStr)
        if not id then
            print("|cff00ccff[RCL]|r Usage: /rcl track <itemID> [threshold]")
            return
        end
        TrackConsumable(id, tonumber(threshStr))
        local th = settings.trackedConsumables[FindTrackedIndex(id)].threshold
        print(string.format("|cff00ccff[RCL]|r Tracking %s (id %d), warn below %d.",
            ConsumableName(id), id, th))

    elseif cmd == "untrack" then
        local id = tonumber(rest)
        if not id then
            print("|cff00ccff[RCL]|r Usage: /rcl untrack <itemID>")
            return
        end
        if UntrackConsumable(id) then
            print(string.format("|cff00ccff[RCL]|r Stopped tracking %s.", ConsumableName(id)))
        else
            print(string.format("|cff00ccff[RCL]|r %d was not tracked.", id))
        end

    elseif cmd == "tracklist" then
        PrintTrackedList()

    elseif cmd == "scan" then
        local includeOther = (rest:lower() == "other")
        local results = ScanBags(includeOther)
        if #results == 0 then
            print("|cff00ccff[RCL]|r Bag scan found nothing"
                .. (includeOther and "." or " (consumables only; try '/rcl scan other')."))
            return
        end
        print(string.format("|cff00ccff[RCL]|r Bag scan (%d item%s):",
            #results, #results == 1 and "" or "s"))
        for _, e in ipairs(results) do
            print(string.format("  %s | %s (id %d): %d",
                e.label, ConsumableName(e.id), e.id, e.count))
        end

    elseif cmd == "consumables" or cmd == "cons" then
        EnsureConsumablesFrame()
        UpdateConsumablesDisplay()
        RCLConsumablesFrame:Show()

    else
        print("|cff00ccff[RCL]|r Usage: /rcl track / untrack / tracklist / scan / consumables")
    end
end

SLASH_RCLDEBUG1 = "/rcldebug"
SlashCmdList["RCLDEBUG"] = function()
    local _, _, diffID, _, _, _, _, instID = GetInstanceInfo()
    local presetID  = settings.dungeonPresets[instID]
    local specIndex = C_SpecializationInfo.GetSpecialization()
    local specID    = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex) or nil
    local currentID = specID and C_ClassTalents.GetLastSelectedSavedConfigID(specID) or nil

    print("|cff00ccff[RCL Debug]|r ------------------")
    print("Location ID:", instID, "| Difficulty:", diffID, "| isMythic:", IsMythicDifficulty(diffID))
    print("Auto-Switch Enabled:", settings.autoSwitch)
    print("Output Channel:", settings.outputChannel, "(resolves to:", GetActiveChannel() .. ")")
    print("Frame Scale:", settings.frameScale, "| Opacity:", settings.frameOpacity, "| Locked:", settings.lockFrame)
    print("Assigned Preset ID:", presetID or "None")
    print("Current Talent ID:", currentID)
    print("Can Change Talents API:", C_ClassTalents.CanChangeTalents())
    if presetID and currentID and presetID == currentID then
        print("Status: Correct talents already equipped.")
    elseif presetID and currentID and presetID ~= currentID then
        print("Status: Ready to switch on next /readycheck.")
    end

    local catalogCategories, catalogItems = 0, 0
    for _, category in ipairs(RCL.CONSUMABLE_CATALOG or {}) do
        catalogCategories = catalogCategories + 1
        catalogItems = catalogItems + #(category.items or {})
    end
    print(string.format("Catalog: %d categories, %d items.", catalogCategories, catalogItems))
    print(string.format("Tracked: %d consumables.", #settings.trackedConsumables))
    PrintTrackedList()
end
