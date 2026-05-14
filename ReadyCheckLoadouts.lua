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
    outputChannel    = "SAY",    -- NEW: chat channel for announcements
    autoSwitch       = false,
    dungeonPresets   = {},       -- [DungeonID] = ConfigID
    frameScale       = 1.0,      -- NEW
    frameOpacity     = 1.0,      -- NEW
    lockFrame        = false,    -- NEW
    -- framePoint is added dynamically when the user drags the window
}

local settings = CopyTable(DEFAULT_SETTINGS)

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

-- ============================================================
-- Data Constants (Midnight Season 1)
-- ============================================================
local seasonalDungeons = {
    { name = "Magisters' Terrace",       id = 2811 },
    { name = "Maisara Caverns",          id = 2669 },
    { name = "Nexus-Point Xenas",        id = 2651 },
    { name = "Windrunner Spire",         id = 2648 },
    { name = "Algeth'ar Academy",        id = 2526 },
    { name = "Seat of the Triumvirate",  id = 1753 },
    { name = "Skyreach",                 id = 1209 },
    { name = "Pit of Saron",             id = 658  },
}

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

    frame:Show()
end

-- ============================================================
-- Options Frame (lazy-built on first /rcl)
-- ============================================================
local optionsFrame
local raidCheckbox, dungeonCheckbox, sayCheckbox, sayRunesCheckbox, lootSpecCheckbox, autoCheckbox
local durabilityCheckbox, sayDurabilityCheckbox, lockFrameCheckbox
local scaleSlider, opacitySlider, channelDropdown

local function UpdateChannelDropdownText()
    if channelDropdown then
        channelDropdown:SetText(GetChannelLabel(settings.outputChannel))
    end
end

local function EnsureOptionsFrame()
    if optionsFrame then return end
    optionsFrame = CreateFrame("Frame", "RCLOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(580, 480)
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

    -- === Column 1: Announcements ===
    local sayHeader = CreateSectionHeader("Announcements", durabilityCheckbox, -16)

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

        for _, dungeon in ipairs(seasonalDungeons) do
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
        for _, dungeon in ipairs(seasonalDungeons) do
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
        print("|cff00ccff[RCL]|r All dungeon presets cleared.")
    end)
    AddSimpleTooltip(clearBtn, "Clear All Presets", "Removes all assigned dungeon talent presets from your database.")

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
eFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        LoadSettings()
        ApplyFrameAppearance()

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
-- Slash Commands
-- ============================================================
SLASH_RCLLOADOUTS1 = "/rcl"
SlashCmdList["RCLLOADOUTS"] = function()
    EnsureOptionsFrame()
    if optionsFrame:IsShown() then
        optionsFrame:Hide()
    else
        UpdateOptionsDisplay()
        optionsFrame:Show()
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
end
