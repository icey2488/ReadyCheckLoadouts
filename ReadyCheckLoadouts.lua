-- ReadyCheckLoadouts.lua
local addonName, RCL = ...

-- ============================================================
-- Settings & Database
-- ============================================================

local DEFAULT_SETTINGS = {
    showInRaid = true,
    showInDungeon = true,
    sayLoadout = true,
    sayRunes = false,
    showLootSpec = true,
    autoSwitch = false,
    dungeonPresets = {}, -- [DungeonID] = ConfigID
}

local settings = CopyTable(DEFAULT_SETTINGS)

local function LoadSettings()
    ReadyCheckLoadoutsDB = ReadyCheckLoadoutsDB or {}
    for k in pairs(DEFAULT_SETTINGS) do
        if ReadyCheckLoadoutsDB[k] ~= nil then
            settings[k] = ReadyCheckLoadoutsDB[k]
        end
    end
    -- One live reference; SavedVariables serializes this at logout.
    ReadyCheckLoadoutsDB = settings
end

-- ============================================================
-- Data Constants (Midnight Season 1)
-- ============================================================

local seasonalDungeons = {
    { name = "Magisters' Terrace", id = 2811 },
    { name = "Maisara Caverns", id = 2669 },
    { name = "Nexus-Point Xenas", id = 2651 },
    { name = "Windrunner Spire", id = 2648 },
    { name = "Algeth'ar Academy", id = 2526 },
    { name = "Seat of the Triumvirate", id = 1753 },
    { name = "Skyreach", id = 1209 },
    { name = "Pit of Saron", id = 658 },
}

local MPLUS_DIFFICULTY  = DifficultyUtil.ID.MythicKeystone
local MYTHIC_DIFFICULTY = DifficultyUtil.ID.DungeonMythic

local function IsMythicDifficulty(diffID)
    return diffID == MPLUS_DIFFICULTY or diffID == MYTHIC_DIFFICULTY
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
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
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

local runeLoadoutLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
runeLoadoutLabel:SetTextColor(0.8, 0.8, 0.8)
runeLoadoutLabel:SetPoint("TOPLEFT", lootSpecLabel, "BOTTOMLEFT", 0, -15)
runeLoadoutLabel:Hide()

local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
closeBtn:SetScript("OnClick", function() frame:Hide() end)

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
        SendChatMessage("Talents: " .. intendedTalentName, "SAY")
    end

    if settings.sayRunes and classFilename == "DEATHKNIGHT" and runeTextOutput ~= "" then
        local cleanRuneText = runeTextOutput:gsub("|c........", ""):gsub("|r", "")
        SendChatMessage(cleanRuneText, "SAY")
    end

    frame:Show()
end

-- ============================================================
-- Options Frame (lazy-built on first /rcl)
-- ============================================================

local optionsFrame
local raidCheckbox, dungeonCheckbox, sayCheckbox, sayRunesCheckbox, lootSpecCheckbox, autoCheckbox

local function EnsureOptionsFrame()
    if optionsFrame then return end

    optionsFrame = CreateFrame("Frame", "RCLOptionsFrame", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(400, 430)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)

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

    local optTitle = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    optTitle:SetPoint("TOP", optionsFrame, "TOP", 0, -18)
    optTitle:SetText("ReadyCheck Loadouts Options")

    raidCheckbox = CreateCheck("Show window during Raid", optTitle, -40)
    raidCheckbox:SetScript("OnClick", function(self) settings.showInRaid = self:GetChecked() end)
    AddSimpleTooltip(raidCheckbox, "Raid Ready Check", "Displays the loadout window when a ready check fires inside a raid instance.")

    dungeonCheckbox = CreateCheck("Show window during Dungeon", raidCheckbox, -10)
    dungeonCheckbox:SetScript("OnClick", function(self) settings.showInDungeon = self:GetChecked() end)
    AddSimpleTooltip(dungeonCheckbox, "Dungeon Ready Check", "Displays the loadout window when a ready check fires inside a dungeon instance.")

    sayCheckbox = CreateCheck("Output loadout in /say", dungeonCheckbox, -10)
    sayCheckbox:SetScript("OnClick", function(self) settings.sayLoadout = self:GetChecked() end)
    AddSimpleTooltip(sayCheckbox, "Announce Loadout", "Announces your active talent loadout name in /say so your group can see it.")

    sayRunesCheckbox = CreateCheck("Output Runes in /say (DK Only)", sayCheckbox, -10)
    sayRunesCheckbox:SetScript("OnClick", function(self) settings.sayRunes = self:GetChecked() end)
    AddSimpleTooltip(sayRunesCheckbox, "Announce Runes", "Announces your active Runeforge enchants in /say when a ready check fires.")

    lootSpecCheckbox = CreateCheck("Show Loot Specialization", sayRunesCheckbox, -10)
    lootSpecCheckbox:SetScript("OnClick", function(self) settings.showLootSpec = self:GetChecked() end)
    AddSimpleTooltip(lootSpecCheckbox, "Loot Specialization", "Displays your active loot specialization on the ready check window. Shows 'Active Spec' if you haven't set a separate loot spec.")

    autoCheckbox = CreateCheck("Auto-switch to preset in M+", lootSpecCheckbox, -10)
    autoCheckbox:SetScript("OnClick", function(self) settings.autoSwitch = self:GetChecked() end)
    AddSimpleTooltip(autoCheckbox, "Auto-Switch Talents", "Automatically changes your talents to the assigned preset for the current Mythic/Mythic+ dungeon when a ready check fires.")

    local dropdownLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dropdownLabel:SetPoint("TOPLEFT", autoCheckbox, "BOTTOMLEFT", 0, -20)
    dropdownLabel:SetText("Assign Dungeon Presets:")

    local dungeonDropdown = CreateFrame("DropdownButton", "RCLDungeonDropdown", optionsFrame, "WowStyle1DropdownTemplate")
    dungeonDropdown:SetPoint("TOPLEFT", dropdownLabel, "BOTTOMLEFT", 0, -10)
    dungeonDropdown:SetWidth(200)
    dungeonDropdown:SetText("Configure Presets...")
    dungeonDropdown.UpdateText = function(self) end -- lock text; see note in review

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

    local testBtn = CreateFrame("Button", nil, optionsFrame, "GameMenuButtonTemplate")
    testBtn:SetSize(140, 24)
    testBtn:SetPoint("BOTTOMLEFT", optionsFrame, "BOTTOMLEFT", 50, 20)
    testBtn:SetText("Test Window")
    testBtn:SetScript("OnClick", function()
        optionsFrame:Hide()
        ShowLoadoutWindow()
    end)
    AddSimpleTooltip(testBtn, "Test Window", "Simulates a ready check to let you preview how your loadout window looks.")

    local clearBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    clearBtn:SetSize(140, 24)
    clearBtn:SetPoint("BOTTOMRIGHT", optionsFrame, "BOTTOMRIGHT", -50, 20)
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
    autoCheckbox:SetChecked(settings.autoSwitch)
end

-- ============================================================
-- Events & Controller
-- ============================================================

local eFrame = CreateFrame("Frame")
eFrame:RegisterEvent("ADDON_LOADED")
eFrame:RegisterEvent("READY_CHECK")
eFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        LoadSettings()

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
    local presetID = settings.dungeonPresets[instID]
    local specIndex = C_SpecializationInfo.GetSpecialization()
    local specID = specIndex and C_SpecializationInfo.GetSpecializationInfo(specIndex) or nil
    local currentID = specID and C_ClassTalents.GetLastSelectedSavedConfigID(specID) or nil

    print("|cff00ccff[RCL Debug]|r ------------------")
    print("Location ID:", instID, "| Difficulty:", diffID, "| isMythic:", IsMythicDifficulty(diffID))
    print("Auto-Switch Enabled:", settings.autoSwitch)
    print("Assigned Preset ID:", presetID or "None")
    print("Current Talent ID:", currentID)
    print("Can Change Talents API:", C_ClassTalents.CanChangeTalents())
    if presetID and currentID and presetID == currentID then
        print("Status: Correct talents already equipped.")
    elseif presetID and currentID and presetID ~= currentID then
        print("Status: Ready to switch on next /readycheck.")
    end
end